-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local logTag = ''

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')
local audioTiming = require('/lua/ge/extensions/gameplay/rally/audioTiming')
local waypointTypes = require('/lua/ge/extensions/gameplay/rally/notebook/waypointTypes')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')
-- local Recce = require('/lua/ge/extensions/gameplay/rally/recce')
local cc = require('/lua/ge/extensions/gameplay/rally/util/colors')
local fuelUtils = require('/lua/ge/extensions/gameplay/rally/fuelUtils')

local C = {}

local boolPtr

local subheadingColor = im.ImVec4(226/255, 137/255, 5/255, 1.0)
local warmButtonColor = im.ImVec4(0.85, 0.42, 0.12, 1.0)
local warmButtonHoveredColor = im.ImVec4(0.95, 0.52, 0.18, 1.0)
local warmButtonActiveColor = im.ImVec4(0.65, 0.30, 0.08, 1.0)
local warmButtonTextColor = im.ImVec4(0.08, 0.06, 0.04, 1.0)
local coldButtonColor = im.ImVec4(0.16, 0.38, 0.72, 1.0)
local coldButtonHoveredColor = im.ImVec4(0.24, 0.50, 0.88, 1.0)
local coldButtonActiveColor = im.ImVec4(0.10, 0.26, 0.54, 1.0)
local recceButtonColor = im.ImVec4(0.15, 0.78, 0.68, 1.0)
local recceButtonHoveredColor = im.ImVec4(0.22, 0.92, 0.80, 1.0)
local recceButtonActiveColor = im.ImVec4(0.10, 0.58, 0.50, 1.0)
local recceButtonTextColor = im.ImVec4(0.04, 0.07, 0.06, 1.0)
local aquaTooltipColor = im.ImVec4(0, 1, 1, 1)

local function drawAquaTooltip(text)
  im.SameLine()
  im.TextColored(aquaTooltipColor, "(?)")
  im.tooltip(text)
end

function C:init()
  -- self.drivelineMode = RallyEnums.drivelineMode.route

  self.nextPacenoteIdxForAudioTriggerTesting = nil
  self.nextPacenoteIdxForAudioTriggerTesting = nil

  self.recce = nil

  self.rallyManager = nil
  self.race = nil
  self.debugLogging = false
  self.cornerGapMsPtr = im.IntPtr(0)
  self.phraseGapMsPtr = im.IntPtr(0)
  self.linkWordGapMsPtr = im.IntPtr(0)
  self.pacenoteGapMsPtr = im.IntPtr(0)
  self.rallyRecoveryCorridorWidthPtr = im.IntPtr(8)
  self.rallyRecoveryBackoffDistancePtr = im.IntPtr(3)
  self.rallyRecoveryResetVehicle = true
  self.rallyRecoveryTestMessage = nil
  self.vehiclePlacementActive = false
  self.vehiclePlacementMessage = nil
  self.selectedPrefabId = nil

  -- voicepack picker / info block cache. Rebuilt on mission change, pick change, or
  -- explicit runtime resync / asset rebuild. See C:_invalidateVoicepackCache and the picker/info
  -- block code in C:draw / C:drawVoicepackPicker. Use `false` (not nil) to mean "no value
  -- yet" so we can distinguish from a real nil missionDir/pick.
  self._vpCache = {
    missionDir = false,
    pickKey    = false,
    entries    = nil,
    label      = nil,
  }

  self.debug = {
    drawRacePath = false,
    drawRaceSplits = false,
    drawRaceAiRoute = false,
    drawRaceCurrentSeg = true,
    drawStartFinishLines = false,
    drawStopZone = false,
    drawNotebookPacenotes = false,
    drawDrivelineRoute = false,
    drawDrivelineRouteStatic = false,
    useMouseRayCast = false,
    -- drawPreRoutePoints = false,
    drawRoutePacenotes = false,
    drawRoutePacenoteText = false,
    drawRoutePathnodes = false,
    drawRoutePointI = false,
    drawRoutePointMetadata = false,
    drawRouteHiddenPathnodes = false,
    drawRouteNextPacenoteWpFromRecalc = false,
    drawRouteNextRacePathnodeFromRecalc = false,
    drawRouteRecoveryTracker = false,
    drawStageTimingFootprints = false,
    drawStageNextPathnode = false,
    drawRouteCompletion = false,
    drawRouteShort = true,
    drawReccePacenotes = true,
    drawDynamicTriggerPoint = true,
    -- drawRecceDrivelinePoints = false,
    drawVehicleTracker = false
  }
end

function C:setRallyManager(rallyManager)
  self.rallyManager = rallyManager
  self:_invalidateVoicepackCache()
end

local function _vpPickKey(pick)
  if not pick or pick.type == 'auto' or pick.type == 'preferences' then return 'preferences' end
  return (pick.type or '?')..'|'..(pick.id or '')..'|'..(pick.scope or 'global')..'|'..(pick.dirname or '')
end

function C:_invalidateVoicepackCache()
  local c = self._vpCache
  c.missionDir = false
  c.pickKey    = false
  c.entries    = nil
  c.label      = nil
end

function C:setDebugLogging(debugLogging)
  self.debugLogging = debugLogging
end

function C:getRallyManager()
  if self.rallyManager then
    return self.rallyManager
  else
    return gameplay_rally.getRallyManager()
  end
end

function C:getDebugLogging()
  -- if self.debugLogging then
    return self.debugLogging
  -- else
    -- return gameplay_rally.getDebugLogging()
  -- end
end

-- Voicepack picker dropdown. Entry shape: { label, pick = { type, scope, dirname } }.
-- Picker entries are built once per mission load and cached on the toolbox instance.
-- The closed-combo label is cached per (missionDir, pick) pair. Both rebuild only on
-- mission change, on user pick change, or on runtime resync / asset rebuild.
-- TODO: persist the pick across sessions (currently in-memory only).
function C:drawVoicepackPicker(rm)
  local missionDir = rm and rm:getMissionDir() or nil
  local missionId = rm and rm:getMissionId() or nil
  local currentPick = rm:getVoicepackPick()
  local c = self._vpCache

  if c.missionDir ~= missionDir then
    c.entries    = voicepack.buildPickerEntries(missionDir, { includePreferences = true, missionId = missionId, missionSuffix = '(mission)', writeSettings = false })
    c.missionDir = missionDir
    c.pickKey    = false
    c.label      = nil
  end

  local pickKey = _vpPickKey(currentPick)
  if c.pickKey ~= pickKey then
    local label = c.entries[1] and c.entries[1].label or '<none>'
    for _, e in ipairs(c.entries) do
      if voicepack.picksMatch(e.pick, currentPick) then
        label = e.label
        break
      end
    end
    c.label   = label
    c.pickKey = pickKey
  end

  im.SetNextItemWidth(360)
  if im.BeginCombo("Voicepack##rallyVoicepackPicker", c.label) then
    for _, e in ipairs(c.entries) do
      local isCurrent = voicepack.picksMatch(e.pick, currentPick)
      if im.Selectable1(e.label, isCurrent) then
        if not isCurrent then
          self:_invalidateVoicepackCache()
          self:clearReccePoints()
          if not rm:reloadVoicepackAssets(e.pick, { writeSettings = false }) then
            log('E', logTag, 'failed to reload RallyManager assets after voicepack pick change')
          end
        end
      end
    end
    im.EndCombo()
  end

  im.SameLine()
  if im.Button("Refresh##rallyVoicepackRefresh") then
    voicepack.invalidateCache()
    voicepack.invalidateMissionCache(missionDir)
    self:_invalidateVoicepackCache()
  end
end

-- function C:setDrivelineMode(drivelineMode)
--   self.drivelineMode = drivelineMode
-- end

-- function C:raceDistanceKmString()
--   local rm = self:getRallyManager()
--   if not rm then return 'N/A' end
--   local dr = rm:getDrivelineRoute()
--   if dr then
--     return dr:getDistanceKmString()
--   end
-- end

-- Returns the current race object, and assigns debug colors to each segment if not already set.
-- Alternates colors between orange and yellow for visual debugging.
function C:getRace()
  if not extensions.isExtensionLoaded("gameplay_rally") then
    return nil
  end

  local race = gameplay_rally.getRace()
  if not race then return nil end
  local path = race.path
  if path then
    local segments = path.segments.sorted
    if segments and segments[1] and not segments[1].missing and not segments[1]._rallyDebugColor then
      for i, seg in ipairs(segments) do
        -- Alternate debug color for each segment: orange for even, yellow for odd
        if i % 2 == 0 then
          seg._rallyDebugColor = {1,0.5,0}
        else
          seg._rallyDebugColor = {1,1,0}
        end
      end
    end
  end
  return race
end

function C:setMouseAsVehicleEnabled(enabled)
  self.debug.useMouseRayCast = enabled == true

  local rm = self:getRallyManager()
  local dr = rm and rm:getDrivelineRoute()
  if dr then
    dr:setTrackMouseLikeVehicle(self.debug.useMouseRayCast)
    dr:enableTrackMouseLikeVehicleMovement(self.debug.useMouseRayCast)
  end
end

function C:toggleMouseMovementCheckbox()
  self:setMouseAsVehicleEnabled(not self.debug.useMouseRayCast)
end

function C:drawLoopTools()
  if not im.CollapsingHeader1("Rally Loop", im.TreeNodeFlags_DefaultClosed) then return end

  local loopLoaded = extensions.isExtensionLoaded(RallyUtil.extRallyLoop)
  im.Text("Extension: " .. (loopLoaded and "loaded" or "unloaded"))

  local loadDisabled = loopLoaded
  if loadDisabled then im.BeginDisabled() end
  if im.Button("Load##rallyLoopLoadExtension") then
    extensions.load(RallyUtil.extRallyLoop)
    loopLoaded = extensions.isExtensionLoaded(RallyUtil.extRallyLoop)
  end
  if loadDisabled then im.EndDisabled() end

  im.SameLine()

  local unloadDisabled = not loopLoaded
  if unloadDisabled then im.BeginDisabled() end
  if im.Button("Unload##rallyLoopUnloadExtension") then
    extensions.unload(RallyUtil.extRallyLoop)
    loopLoaded = extensions.isExtensionLoaded(RallyUtil.extRallyLoop)
  end
  if unloadDisabled then im.EndDisabled() end

  local debugDisabled = not loopLoaded or not gameplay_rallyLoop or not gameplay_rallyLoop.toggleDebug
  if debugDisabled then im.BeginDisabled() end
  if im.Button("Toggle Loop Debug Window##rallyLoopToggleDebugWindow") then
    gameplay_rallyLoop.toggleDebug()
  end
  if debugDisabled then im.EndDisabled() end
end

function C:drawRallyRecoveryTools(rm)
  if not im.CollapsingHeader1("Recovery", im.TreeNodeFlags_DefaultClosed) then return end

  local dr = rm and rm.getDrivelineRoute and rm:getDrivelineRoute() or nil
  local tracker = dr and dr.getStaticTrackerState and dr:getStaticTrackerState() or nil
  im.Text("Tracker state: "..tostring(tracker and tracker.state or '<none>'))
  if tracker then
    im.TextWrapped(string.format(
      "lateral=%.2fm segment=%s distToTarget=%.2fm recoveryDist=%.2fm corridor=%.1fm/%.1fm",
      tonumber(tracker.lateralDist) or -1,
      tostring(tracker.segmentIdx),
      tonumber(tracker.distToTarget) or -1,
      tonumber(tracker.recoveryDistToTarget) or -1,
      tonumber(tracker.offRouteDistance) or -1,
      tonumber(tracker.onRouteDistance) or -1
    ))
    local sourceStr = tostring(tracker.projectionSource or "?")
    if tracker.projectionSource == 'full' then
      im.TextColored(im.ImVec4(1, 0.2, 0.2, 1), string.format("projection source: %s  <<< FULL", sourceStr))
    else
      im.Text(string.format("projection source: %s", sourceStr))
    end
    if tracker.departure then
      im.TextWrapped(string.format(
        "departure dist=%.2fm lateral=%.2fm",
        tonumber(tracker.departure.distToTarget) or -1,
        tonumber(tracker.departure.lateralDist) or -1
      ))
    end
  end

  im.SetNextItemWidth(180)
  local corridorWidth = dr and dr.getRouteCorridorWidth and dr:getRouteCorridorWidth()
  if corridorWidth then
    self.rallyRecoveryCorridorWidthPtr[0] = math.floor(corridorWidth + 0.5)
  end
  if im.SliderInt("Corridor half-width (m)##rallyRecoveryCorridorWidth", self.rallyRecoveryCorridorWidthPtr, 1, 15) then
    if dr and dr.setRouteCorridorWidth then
      dr:setRouteCorridorWidth(self.rallyRecoveryCorridorWidthPtr[0])
    end
  end

  im.SetNextItemWidth(180)
  if im.SliderInt("Recovery backoff (m)##rallyRecoveryBackoffDistance", self.rallyRecoveryBackoffDistancePtr, 0, 20) then
    -- value stored in ptr
  end

  boolPtr = im.BoolPtr(self.rallyRecoveryResetVehicle)
  if im.Checkbox("Repair vehicle##rallyRecoveryResetVehicle", boolPtr) then
    self.rallyRecoveryResetVehicle = boolPtr[0]
  end
  im.SameLine()

  boolPtr = im.BoolPtr(self.debug.drawRouteRecoveryTracker)
  if im.Checkbox("Draw tracker markers##rallyRecoveryDrawTracker", boolPtr) then
    self.debug.drawRouteRecoveryTracker = boolPtr[0]
  end

  local recoveryDisabled = not rm or not rm.getRouteDepartureRecoveryPose
  if recoveryDisabled then im.BeginDisabled() end
  if im.Button("Run Recovery##rallyRecoveryRun") then
    local veh = getPlayerVehicle(0)
    local function runRecovery(fuelSnapshot)
      local recoveryVeh = veh and scenetree.findObjectById(veh:getID()) or getPlayerVehicle(0)
      local ok, reason = rm:recoverVehicleToRouteDeparture(recoveryVeh, {
        repairVehicle = self.rallyRecoveryResetVehicle,
        backoffDistance = self.rallyRecoveryBackoffDistancePtr[0],
      })
      if ok then
        if self.rallyRecoveryResetVehicle then
          fuelUtils.applyFuelSnapshot(recoveryVeh, fuelSnapshot, logTag, 'rallyToolboxRouteRecovery')
        end
        self.rallyRecoveryTestMessage = "Recovered to route departure."
        log('I', logTag, self.rallyRecoveryTestMessage)
      else
        self.rallyRecoveryTestMessage = "Recovery failed: "..tostring(reason)
        log('W', logTag, self.rallyRecoveryTestMessage)
      end
    end

    if self.rallyRecoveryResetVehicle and veh then
      self.rallyRecoveryTestMessage = "Recovering to route departure..."
      fuelUtils.requestFuelSnapshot(veh, runRecovery)
    else
      runRecovery(nil)
    end
  end
  if recoveryDisabled then im.EndDisabled() end

  if self.rallyRecoveryTestMessage then
    im.TextWrapped(self.rallyRecoveryTestMessage)
  end
end

function C:_startVehiclePlacement()
  self.vehiclePlacementActive = true
  self.vehiclePlacementMessage = "Click a position in the 3D viewport."
end

function C:_cancelVehiclePlacement()
  self.vehiclePlacementActive = false
  self.vehiclePlacementMessage = "Vehicle placement canceled."
end

function C:_placeVehicleAt(pos)
  local veh = getPlayerVehicle(0)
  if not veh then
    return false, 'no player vehicle'
  end

  local rot = quatFromDir(vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
  local rm = self:getRallyManager()
  if rm and rm.setPreserveRecoveryTrackerOnNextVehicleReset then
    rm:setPreserveRecoveryTrackerOnNextVehicleReset(true)
  end
  local teleportOk, teleportErr = pcall(function()
    spawn.safeTeleport(veh, vec3(pos), rot, nil, nil, nil, true, false)
  end)
  if not teleportOk then
    if rm and rm.setPreserveRecoveryTrackerOnNextVehicleReset then
      rm:setPreserveRecoveryTrackerOnNextVehicleReset(false)
    end
    return false, teleportErr
  end
  return true
end

function C:_updateVehiclePlacementMode()
  if not self.vehiclePlacementActive then return end

  local rayCast = cameraMouseRayCast()
  if not rayCast or not rayCast.pos then
    self.vehiclePlacementMessage = "Vehicle placement: no valid viewport hit."
    return
  end

  local pos = vec3(rayCast.pos)
  debugDrawer:drawSphere(pos, 1.0, ColorF(0.1, 0.7, 1, 0.8))
  debugDrawer:drawTextAdvanced(
    pos + vec3(0, 0, 1.2),
    String("Place Vehicle"),
    ColorF(0,0,0,1), true, false,
    ColorI(26, 180, 255, 220), false, false)

  local io = im.GetIO()
  if im.IsMouseClicked(1) and not io.WantCaptureMouse then
    self:_cancelVehiclePlacement()
    return
  end

  if im.IsMouseClicked(0) and not io.WantCaptureMouse then
    local ok, reason = self:_placeVehicleAt(pos)
    self.vehiclePlacementActive = false
    self.vehiclePlacementMessage = ok == false and ("Vehicle placement failed: "..tostring(reason or 'unknown error')) or nil
  end
end

function C:drawVehicleTools()
  if not im.CollapsingHeader1("Vehicle", im.TreeNodeFlags_DefaultClosed) then return end

  if im.Button("Place Vehicle##rallyVehiclePlace") then
    self:_startVehiclePlacement()
  end

  if self.vehiclePlacementActive then
    im.SameLine()
    if im.Button("Cancel##rallyVehiclePlacementCancel") then
      self:_cancelVehiclePlacement()
    end
  end

  if self.vehiclePlacementMessage then
    im.SameLine()
    im.Text(self.vehiclePlacementMessage)
  end
end

local function getTopLevelPrefabs()
  local missionGroup = scenetree.MissionGroup
  if not missionGroup then return {} end

  local prefabs = {}
  for i = 0, missionGroup:size() - 1 do
    local obj = missionGroup:at(i)
    local className = obj and obj:getClassName()
    if className == "Prefab" or className == "PrefabInstance" then
      table.insert(prefabs, {
        id = obj:getID(),
        name = obj:getName() ~= "" and obj:getName() or ("<unnamed "..className..">"),
        className = className,
      })
    end
  end

  table.sort(prefabs, function(a, b)
    local aName = string.lower(a.name)
    local bName = string.lower(b.name)
    return aName == bName and a.id < b.id or aName < bName
  end)
  return prefabs
end

function C:_spawnPrefab(filepath, ownerMissionId)
  local missionGroup = scenetree.MissionGroup
  if not missionGroup then return end

  local filename = filepath:match("([^/\\]+)$") or "prefab"
  local prefabLabel = filename:gsub("%.prefab%.json$", ""):gsub("%.prefab$", "")
  local rm = self:getRallyManager()
  ownerMissionId = ownerMissionId or (rm and rm:getMissionId())
  local objectName = ownerMissionId and (ownerMissionId.." - "..prefabLabel) or prefabLabel
  local prefab = spawnPrefab(Sim.getUniqueName(objectName), filepath, "0 0 0", "0 0 1 0", "1 1 1")
  if not prefab then
    log('E', logTag, 'failed to spawn prefab: '..tostring(filepath))
    return
  end

  prefab.loadMode = 0
  missionGroup:addObject(prefab.obj)
  self.selectedPrefabId = prefab.obj:getId()
end

local function findMissionPrefab(missionDir, prefabName)
  if not missionDir then return nil end

  local dir = missionDir:sub(-1) == "/" and missionDir or missionDir.."/"
  for _, extension in ipairs({".prefab", ".prefab.json"}) do
    local filepath = dir..prefabName..extension
    if FS:fileExists(filepath) then
      return filepath
    end
  end
end

local function extractMissionId(value)
  if not value or value == "" or value == "<none>" then return nil end
  return value:match("%((.+)%)$") or value
end

local function rallyLoopContainsMission(loopMission, missionId)
  local variables = loopMission and (loopMission.fgVariables or loopMission.missionTypeData)
  if not variables then return false end

  for stageNum = 1, 4 do
    if extractMissionId(variables["stage"..stageNum.."_rallyRoadSection"]) == missionId
      or extractMissionId(variables["stage"..stageNum.."_rallyStage"]) == missionId then
      return true
    end
  end

  return extractMissionId(variables.return_rallyRoadSection) == missionId
end

local function findRallyLoopsForMission(missionId)
  if not missionId or not gameplay_missions_missions then return {} end

  local mission = gameplay_missions_missions.getMissionById(missionId)
  local level = mission and mission.startTrigger and mission.startTrigger.level
  if not level then return {} end

  local matchingLoops = {}
  local loopMissions = gameplay_missions_missions.getMissionsByFilter({
    missionType = "rallyLoop",
    level = level,
  })
  for _, loopMission in ipairs(loopMissions) do
    if rallyLoopContainsMission(loopMission, missionId) then
      table.insert(matchingLoops, loopMission)
    end
  end

  table.sort(matchingLoops, function(a, b) return a.id < b.id end)
  return matchingLoops
end

function C:drawPrefabTools()
  if not im.CollapsingHeader1("Prefabs", im.TreeNodeFlags_DefaultClosed) then return end

  local missionGroupAvailable = scenetree.MissionGroup ~= nil
  local rm = self:getRallyManager()
  local missionDir = rm and rm:getMissionDir()
  local missionId = rm and rm:getMissionId()
  local missionPrefabNames = {"mainPrefab", "fwdPrefab"}
  for i, prefabName in ipairs(missionPrefabNames) do
    local filepath = findMissionPrefab(missionDir, prefabName)
    local spawnDisabled = not missionGroupAvailable or not filepath
    if spawnDisabled then im.BeginDisabled() end
    if im.Button("Spawn "..prefabName.."##rallyPrefabSpawn"..prefabName) then
      self:_spawnPrefab(filepath)
    end
    if spawnDisabled then im.EndDisabled() end
    if i < #missionPrefabNames then im.SameLine() end
  end

  local containingLoops = findRallyLoopsForMission(missionId)
  if #containingLoops > 0 then
    local loopPrefabPath = findMissionPrefab(missionDir, "loopPrefab")
    local loopPrefabDisabled = not missionGroupAvailable or not loopPrefabPath
    if loopPrefabDisabled then im.BeginDisabled() end
    if im.Button("Spawn loopPrefab##rallyPrefabSpawnLoopPrefab") then
      self:_spawnPrefab(loopPrefabPath)
    end
    if loopPrefabDisabled then im.EndDisabled() end

    for _, loopMission in ipairs(containingLoops) do
      local loopMissionDir = loopMission.missionFolder or RallyUtil.missionDirHelper(loopMission.id)
      local loopMainPrefabPath = findMissionPrefab(loopMissionDir, "mainPrefab")
      local loopMainPrefabDisabled = not missionGroupAvailable or not loopMainPrefabPath
      if loopMainPrefabDisabled then im.BeginDisabled() end
      local loopName = loopMission.name and _tr(loopMission.name) or loopMission.id
      if im.Button("Spawn loop mainPrefab: "..loopName.."##rallyPrefabSpawnLoopMain"..loopMission.id) then
        self:_spawnPrefab(loopMainPrefabPath, loopMission.id)
      end
      if loopMainPrefabDisabled then im.EndDisabled() end
    end
  end

  local prefabs = getTopLevelPrefabs()
  local selectedLabel = "<select prefab>"
  local selectedExists = false
  for _, prefab in ipairs(prefabs) do
    if prefab.id == self.selectedPrefabId then
      selectedLabel = prefab.name
      selectedExists = true
      break
    end
  end
  if not selectedExists then
    local firstPrefab = prefabs[1]
    self.selectedPrefabId = firstPrefab and firstPrefab.id or nil
    selectedLabel = firstPrefab and firstPrefab.name or "<select prefab>"
  end

  im.SetNextItemWidth(360)
  if im.BeginCombo("Top-level Prefab##rallyPrefabPicker", selectedLabel) then
    for _, prefab in ipairs(prefabs) do
      local isSelected = prefab.id == self.selectedPrefabId
      if im.Selectable1(prefab.name.."##rallyPrefab"..prefab.id, isSelected) then
        self.selectedPrefabId = prefab.id
      end
    end
    im.EndCombo()
  end

  im.SameLine()
  local removeDisabled = not self.selectedPrefabId
  if removeDisabled then im.BeginDisabled() end
  if im.Button("Remove##rallyPrefabRemove") then
    local prefab = scenetree.findObjectById(self.selectedPrefabId)
    if prefab then
      prefab:delete()
    end
    self.selectedPrefabId = nil
  end
  if removeDisabled then im.EndDisabled() end
end

function C:draw()
  local rm = self:getRallyManager()
  local missionName = '<none>'
  if rm then
    missionName = rm:getMissionName()
  end
  im.HeaderText("Mission: " .. missionName)

  if rm then
    local dr = rm:getDrivelineRoute()
    if dr then
      im.Text(tostring(rm:getMissionId()) .. " | " .. dr:getDistanceKmString())
      if dr and dr:isLoaded() then
        -- im.Text("driveline loaded.")
      else
        im.TextColored(im.ImVec4(1,0,0,1), "driveline load failed!")
      end
    else
      im.Text(tostring(rm:getMissionId()) .. " | N/A")
      im.Text("Driveline Distance: N/A")
    end
  end

  im.PushStyleColor2(im.Col_Button, warmButtonColor)
  im.PushStyleColor2(im.Col_ButtonHovered, warmButtonHoveredColor)
  im.PushStyleColor2(im.Col_ButtonActive, warmButtonActiveColor)
  im.PushStyleColor2(im.Col_Text, warmButtonTextColor)
  if im.Button("Warm Reload##debugRmVhclRuntimeResync") then
    self:clearReccePoints()
    if rm then
      if not rm:runtimeResync() then
        log('E', logTag, 'failed to runtimeResync RallyManager')
      end
      self:_invalidateVoicepackCache()
    end
  end
  im.PopStyleColor(4)
  im.tooltip("Clears runtime queues and schedules driveline runtime state to resync without reloading notebooks, routes, or voicepack assets.")
  im.SameLine()
  im.PushStyleColor2(im.Col_Button, coldButtonColor)
  im.PushStyleColor2(im.Col_ButtonHovered, coldButtonHoveredColor)
  im.PushStyleColor2(im.Col_ButtonActive, coldButtonActiveColor)
  if im.Button("Cold Reload##debugRmVhclRebuildAssets") then
    self:clearReccePoints()
    if rm then
      -- Asset rebuild is dev-iteration intent: drop the module-level voicepack scan caches
      -- so newly added/edited voicepacks (and their pre-translated strings) get re-scanned.
      voicepack.invalidateCache()
      voicepack.invalidateMissionCache(rm:getMissionDir())
      if not rm:rebuildAssets() then
        log('E', logTag, 'failed to rebuild RallyManager assets')
      end
      self:_invalidateVoicepackCache()
    end
  end
  im.PopStyleColor(3)
  im.tooltip("Clears rally voicepack caches, reloads the active mission route/notebook/driveline data, and resyncs vehicle runtime state.")
  im.SameLine()
  im.PushStyleColor2(im.Col_Button, recceButtonColor)
  im.PushStyleColor2(im.Col_ButtonHovered, recceButtonHoveredColor)
  im.PushStyleColor2(im.Col_ButtonActive, recceButtonActiveColor)
  im.PushStyleColor2(im.Col_Text, recceButtonTextColor)
  if im.Button("Toggle Recce Window##rallyRecceWindow") then
    if gameplay_rally and gameplay_rally.recceApp and gameplay_rally.recceApp.toggleWindow then
      gameplay_rally.recceApp.toggleWindow()
    end
  end
  im.PopStyleColor(4)
  im.tooltip("Open or close the standalone ImGui Recce window for loading rally stages/road sections and moving the vehicle.")

  if im.CollapsingHeader1("Voicepack", im.TreeNodeFlags_DefaultOpen) then
    if rm then
      self:drawVoicepackPicker(rm)

      local pick = rm:getVoicepackPick()
      if not pick or pick.type == 'preferences' or pick.type == 'auto' then
        local missionDir = rm:getMissionDir()
        local missionId = rm:getMissionId()
        local _, resolvedEntry = voicepack.resolveEffectiveEntry(missionDir, pick, { missionId = missionId })
        local resolvedLabel = resolvedEntry and voicepack.labelForEntry(resolvedEntry, resolvedEntry.dirname, resolvedEntry.scope == 'mission' and '(mission)' or nil) or '<none>'
        im.Text('Resolved: '..tostring(resolvedLabel))
      end
    else
      im.Text("(load a mission to see voicepack section)")
    end

    if rm and rm.notebook then
      local nb = rm.notebook
      im.Text('Notebook: '..tostring(nb.name or '<none>')..' ('..tostring(nb:basename() or '<none>')..')')

      local audioManager = rm.getAudioManager and rm:getAudioManager() or nil
      if audioManager then
        local structuredTimingEnabled = nb:isAudioModeOnlineStructured() or nb:isAudioModeOfflineStructured()

        self.cornerGapMsPtr[0] = audioManager:getCornerGapMs()
        im.SetNextItemWidth(180)
        if not structuredTimingEnabled then im.BeginDisabled() end
        if im.SliderInt("Corner Gap (ms)##rallyCornerGapMs", self.cornerGapMsPtr, audioTiming.cornerGapMs.min, audioTiming.cornerGapMs.max) then
          audioManager:setCornerGapMs(self.cornerGapMsPtr[0])
        end
        if not structuredTimingEnabled then im.EndDisabled() end
        drawAquaTooltip("A corner phrase is emitted by the compositor as part of the corner portion of a pacenote, rather than as a modifier, distance call, or link word.\nThis adjusts spacing when one corner phrase immediately follows another within the same pacenote.\nPositive values add silence; negative values overlap the phrases.")

        self.phraseGapMsPtr[0] = audioManager:getPhraseGapMs()
        im.SetNextItemWidth(180)
        if not structuredTimingEnabled then im.BeginDisabled() end
        if im.SliderInt("Phrase Gap (ms)##rallyPhraseGapMs", self.phraseGapMsPtr, audioTiming.phraseGapMs.min, audioTiming.phraseGapMs.max) then
          audioManager:setPhraseGapMs(self.phraseGapMsPtr[0])
        end
        if not structuredTimingEnabled then im.EndDisabled() end
        drawAquaTooltip("Adjusts spacing after other phrases within one pacenote.\nConsecutive corner phrases and link words use their own gap settings.\nPositive values add silence; negative values overlap the phrases.")

        self.linkWordGapMsPtr[0] = audioManager:getLinkWordGapMs()
        im.SetNextItemWidth(180)
        if not structuredTimingEnabled then im.BeginDisabled() end
        if im.SliderInt("Link Word Gap (ms)##rallyLinkWordGapMs", self.linkWordGapMsPtr, audioTiming.linkWordGapMs.min, audioTiming.linkWordGapMs.max) then
          audioManager:setLinkWordGapMs(self.linkWordGapMsPtr[0])
        end
        if not structuredTimingEnabled then im.EndDisabled() end
        drawAquaTooltip("Adjusts spacing after link words such as \"into\" or \"and\".\nPositive values add silence; negative values overlap the phrases.")

        self.pacenoteGapMsPtr[0] = audioManager:getPacenoteGapMs()
        im.SetNextItemWidth(180)
        if not structuredTimingEnabled then im.BeginDisabled() end
        if im.SliderInt("Pacenote Gap (ms)##rallyPacenoteGapMs", self.pacenoteGapMsPtr, audioTiming.pacenoteGapMs.min, audioTiming.pacenoteGapMs.max) then
          audioManager:setPacenoteGapMs(self.pacenoteGapMsPtr[0])
        end
        if not structuredTimingEnabled then im.EndDisabled() end
        drawAquaTooltip("Adjusts spacing after the final phrase of a pacenote before the next pacenote.\nPositive values add silence; negative values overlap the pacenotes.")
      else
        im.Text("Audio Timing: <no audio manager>")
      end
    end
  end

  -- if rm and rm:getDrivelineMode() then
  --   local modeName = RallyEnums.drivelineModeNames[rm:getDrivelineMode()]
  --   im.Text("rallyManager.drivelineMode=" .. tostring(modeName))
  -- end

  -- im.SameLine()
  -- if im.Button("Driveline Route Recalc##debugDrivelineRouteRecalc") then
  --   local rm = self:getRallyManager()
  --   if rm then
  --     if not rm:getDrivelineRoute():recalculate() then
  --       log('E', logTag, 'failed to recalculate')
  --     end
  --   end
  -- end
  -- im.SameLine()

  if rm then
    self:drawRallyRecoveryTools(rm)
  end
  self:drawVehicleTools()
  self:drawPrefabTools()

  if im.CollapsingHeader1("Visual Pacenotes", im.TreeNodeFlags_DefaultClosed) then
    if im.Button("Clear Visual Pacenotes##debugClearVisualPacenotes") then
      if rm then
        rm:triggerClearAllVisualPacenotes()
        rm:resetAudioQueue()
        self.nextPacenoteIdxForAudioTriggerTesting = nil
        self.nextPacenoteIdxForRemoveTesting = nil
      end
    end
    im.SameLine()

    if im.Button("Trigger Next Visual Note##triggerNextVisualNote") then
      if rm then
        local nb = rm:getNotebookPath()
        if nb then
          if not self.nextPacenoteIdxForAudioTriggerTesting then
            self.nextPacenoteIdxForAudioTriggerTesting = 1
          end
          local pacenote = nb.pacenotes.sorted[self.nextPacenoteIdxForAudioTriggerTesting]
          if pacenote and not pacenote.missing then
            rm:triggerShowVisualPacenote(pacenote)
            self.nextPacenoteIdxForAudioTriggerTesting = self.nextPacenoteIdxForAudioTriggerTesting + 1
          else
            log('E', logTag, 'failed to get pacenote, pacenote not found')
          end
        end
      end
    end
    im.SameLine()

    if im.Button("Remove Visual Note##removeNextVisualNote") then
      if rm then
        local nb = rm:getNotebookPath()
        if nb then
          if not self.nextPacenoteIdxForRemoveTesting then
            self.nextPacenoteIdxForRemoveTesting = 1
          end
          local pacenote = nb.pacenotes.sorted[self.nextPacenoteIdxForRemoveTesting]
          if pacenote and not pacenote.missing then
            rm:triggerClearVisualPacenote(pacenote)
            self.nextPacenoteIdxForRemoveTesting = self.nextPacenoteIdxForRemoveTesting + 1
          else
            log('E', logTag, 'failed to get pacenote, pacenote not found')
          end
        end
      end
    end
  end

  if im.CollapsingHeader1("Driveline Visualization", im.TreeNodeFlags_DefaultClosed) then
    -- im.SetNextItemWidth(100)
    -- local defaultMode = RallyEnums.drivelineModeNames[1]
    -- local drivelineMode = RallyEnums.drivelineModeNames[self.drivelineMode]

    -- if rm then
    --   if rmDrivelineMode then
    --     drivelineMode = RallyEnums.drivelineModeNames[rmDrivelineMode]
    --   end
    -- end

    -- if im.BeginCombo("Driveline Mode Override##drivelineMode", drivelineMode) then
    --   for _, mode in ipairs(RallyEnums.drivelineModeNames) do
    --     if im.Selectable1(mode, mode == drivelineMode) then
    --       self.drivelineMode = RallyEnums.drivelineMode[mode]
    --       if rm then
    --         self:clearReccePoints()
    --         -- rm:setDrivelineMode(self.drivelineMode)
    --         if not rm:rebuildAssets() then
    --           log('E', logTag, 'failed to rebuild RallyManager assets')
    --         end
    --       end
    --     end
    --   end
    --   im.EndCombo()
    -- end

    boolPtr = im.BoolPtr(self.debug.drawRouteShort)
    if im.Checkbox("Short Route##debugDrawRouteShort", boolPtr) then
      self.debug.drawRouteShort = boolPtr[0]
    end
    im.SameLine()

    boolPtr = im.BoolPtr(self.debug.drawDynamicTriggerPoint)
    if im.Checkbox("Trigger Point##debugDrawDynamicTriggerPoint", boolPtr) then
      self.debug.drawDynamicTriggerPoint = boolPtr[0]
    end
    im.SameLine()

    boolPtr = im.BoolPtr(self.debug.drawReccePacenotes)
    if im.Checkbox("Next Pacenote##debugDrawReccePacenotes", boolPtr) then
      self.debug.drawReccePacenotes = boolPtr[0]
    end

    boolPtr = im.BoolPtr(self.debug.drawDrivelineRouteStatic)
    if im.Checkbox("Static Route##debugDrawDrivelineRouteStatic", boolPtr) then
      self.debug.drawDrivelineRouteStatic = boolPtr[0]
    end
    im.SameLine()

    boolPtr = im.BoolPtr(self.debug.drawRouteCompletion)
    if im.Checkbox("Completion %##debugDrawRouteCompletion", boolPtr) then
      self.debug.drawRouteCompletion = boolPtr[0]
    end

    boolPtr = im.BoolPtr(self.debug.drawStageNextPathnode)
    if im.Checkbox("Next Pathnode##debugDrawStageNextPathnode", boolPtr) then
      self.debug.drawStageNextPathnode = boolPtr[0]
    end

    -- Deprecated: Live Route Debug compared the old mutable live route path against
    -- static route tracking. Keep the backing flag for legacy draw plumbing, but
    -- hide the toolbox toggle.
    -- boolPtr = im.BoolPtr(self.debug.drawDrivelineRoute)
    -- if im.Checkbox("Live Route Debug (temporary comparison)##debugDrawDrivelineRoute", boolPtr) then
    --   self.debug.drawDrivelineRoute = boolPtr[0]
    -- end

    -- boolPtr = im.BoolPtr(self.debug.drawPreRoutePoints)
    -- local shouldBeDisabled = not rm or not rm.drivelineRoute or not rm.drivelineRoute.preRoutePoints
    -- if shouldBeDisabled then
      -- im.BeginDisabled()
    -- end
    -- if im.Checkbox("PreRoute Points##debugPreRoutePoints", boolPtr) then
    --   self.debug.drawPreRoutePoints = boolPtr[0]
    -- end
    -- if shouldBeDisabled then
    --   im.EndDisabled()
    --   self.debug.drawPreRoutePoints = false
    -- end
    -- im.SameLine()

    boolPtr = im.BoolPtr(self.debug.drawRoutePacenotes)
    if im.Checkbox("Pacenotes##debugDrawRoutePacenotes", boolPtr) then
      self.debug.drawRoutePacenotes = boolPtr[0]
    end
    im.SameLine()

    boolPtr = im.BoolPtr(self.debug.drawRoutePacenoteText)
    if im.Checkbox("Pacenote Text##debugDrawRoutePacenoteText", boolPtr) then
      self.debug.drawRoutePacenoteText = boolPtr[0]
    end

    -- boolPtr = im.BoolPtr(self.debug.drawRecceDrivelinePoints)
    -- if im.Checkbox("Recce Driveline Points##debugDrawRecceDrivelinePoints", boolPtr) then
    --   self.debug.drawRecceDrivelinePoints = boolPtr[0]
    -- end
  end

  if im.CollapsingHeader1("Race Visualization", im.TreeNodeFlags_DefaultClosed) then
    -- Race Path Debug - static track layout from path.lua (always available)
    boolPtr = im.BoolPtr(self.debug.drawRacePath)
    if im.Checkbox("Pathnodes##debugDrawRacePath", boolPtr) then
      self.debug.drawRacePath = boolPtr[0]
    end
    im.SameLine()
    boolPtr = im.BoolPtr(self.debug.drawRaceAiRoute)
    if im.Checkbox("AI Route##debugDrawRaceAiRoute", boolPtr) then
      self.debug.drawRaceAiRoute = boolPtr[0]
    end
    im.SameLine()
    boolPtr = im.BoolPtr(self.debug.drawRaceSplits)
    if im.Checkbox("Splits##debugDrawRaceSplits", boolPtr) then
      self.debug.drawRaceSplits = boolPtr[0]
    end

    boolPtr = im.BoolPtr(self.debug.drawStartFinishLines)
    if im.Checkbox("Start and Finish Lines##debugDrawStartFinishLines", boolPtr) then
      self.debug.drawStartFinishLines = boolPtr[0]
    end
    im.SameLine()
    boolPtr = im.BoolPtr(self.debug.drawStopZone)
    if im.Checkbox("Stop Zone##debugDrawStopZone", boolPtr) then
      self.debug.drawStopZone = boolPtr[0]
    end

    -- Race Debug - dynamic race session from race.lua (optional, only when race is active)
    local shouldBeDisabled = not self:getRace()

    if shouldBeDisabled then im.BeginDisabled() end
    boolPtr = im.BoolPtr(self.debug.drawRaceCurrentSeg)
    if im.Checkbox("Current Segment (Only Available When Race Is Active)##debugDrawRaceCurrentSeg", boolPtr) then
      self.debug.drawRaceCurrentSeg = boolPtr[0]
    end
    if shouldBeDisabled then im.EndDisabled() end
  end


  if im.CollapsingHeader1("Low-Level Visualizations", im.TreeNodeFlags_DefaultClosed) then
    boolPtr = im.BoolPtr(self.debug.drawStageTimingFootprints)
    if im.Checkbox("Timing Footprints##debugDrawStageTimingFootprints", boolPtr) then
      self.debug.drawStageTimingFootprints = boolPtr[0]
    end
    im.SameLine()

    boolPtr = im.BoolPtr(self.debug.drawVehicleTracker)
    if im.Checkbox("Vehicle Tracker##debugDrawVehicleTracker", boolPtr) then
      self.debug.drawVehicleTracker = boolPtr[0]
    end

    boolPtr = im.BoolPtr(self.debug.drawRouteNextPacenoteWpFromRecalc)
    if im.Checkbox("Next PacenoteWaypoint##debugDrawRouteNextPacenoteWp", boolPtr) then
      self.debug.drawRouteNextPacenoteWpFromRecalc = boolPtr[0]
    end
    im.SameLine()

    boolPtr = im.BoolPtr(self.debug.drawRouteNextRacePathnodeFromRecalc)
    if im.Checkbox("Next Race Pathnode##debugDrawRouteNextRacePathnode", boolPtr) then
      self.debug.drawRouteNextRacePathnodeFromRecalc = boolPtr[0]
    end

    boolPtr = im.BoolPtr(self.debug.drawRoutePathnodes)
    if im.Checkbox("Pathnodes##debugDrawRoutePathnodes", boolPtr) then
      self.debug.drawRoutePathnodes = boolPtr[0]
    end
    im.SameLine()

    boolPtr = im.BoolPtr(self.debug.drawRouteHiddenPathnodes)
    if im.Checkbox("Hidden Pathnodes##debugDrawRouteHiddenPathnodes", boolPtr) then
      self.debug.drawRouteHiddenPathnodes = boolPtr[0]
    end

    boolPtr = im.BoolPtr(self.debug.drawNotebookPacenotes)
    if im.Checkbox("Raw Pacenotes##debugDrawNotebookPacenotes", boolPtr) then
      self.debug.drawNotebookPacenotes = boolPtr[0]
    end
    im.tooltip("Draws the original notebook pacenote corner-start/corner-end waypoint labels, before route projection/metadata attachment.")

    boolPtr = im.BoolPtr(self.debug.drawRoutePointI)
    if im.Checkbox("Point Index##debugDrawRoutePointI", boolPtr) then
      self.debug.drawRoutePointI = boolPtr[0]
    end
    im.SameLine()

    boolPtr = im.BoolPtr(self.debug.drawRoutePointMetadata)
    if im.Checkbox("Point Metadata##debugDrawRoutePointMetadata", boolPtr) then
      self.debug.drawRoutePointMetadata = boolPtr[0]
    end
  end

  if im.CollapsingHeader1("Use Mouse as Vehicle", im.TreeNodeFlags_DefaultClosed) then
    boolPtr = im.BoolPtr(self.debug.useMouseRayCast)
    if im.Checkbox("Enable##debugUseMouseRayCast", boolPtr) then
      self:setMouseAsVehicleEnabled(boolPtr[0])
    end
    im.Text("Hold Shift to read the mouse position. Shift-click to skip to the clicked position.")
  end

  self:drawLoopTools()

  self:drawDebug()
end

-- function C:loadReccePoints()
--   if self.recce then return end

--   local rm = self:getRallyManager()
--   if not rm then
--     log('E', logTag, 'failed to load recce points, rally manager not found')
--     return
--   end

--   local md = rm:getMissionDir()
--   if not md then
--     log('E', logTag, 'failed to load recce points, mission dir not found')
--     return
--   end

--   local recce = Recce(md)
--   if not recce:loadDrivelineAndCuts() then
--     log('E', logTag, 'failed to load recce driveline and cuts for refresh')
--   end

--   self.recce = recce
-- end

function C:clearReccePoints()
  self.recce = nil
end

local function drawPointSet(points, previousPoints, pointColor, previousColor, lineColor, radius, label)
  if not points then return end
  for i, point in ipairs(points) do
    if point then
      debugDrawer:drawSphere(point, radius, pointColor)
      if previousPoints and previousPoints[i] then
        debugDrawer:drawSphere(previousPoints[i], radius * 0.75, previousColor)
        debugDrawer:drawLine(previousPoints[i], point, lineColor)
      end
      if i == 1 and label then
        debugDrawer:drawTextAdvanced(
          point + vec3(0, 0, 0.6),
          String(label),
          ColorF(0, 0, 0, 1),
          true,
          false,
          ColorI(255, 255, 255, 220),
          false,
          false
        )
      end
    end
  end
end

local function drawStageTimingFootprints(rm)
  if not rm or not rm.vehicleTracker then return end

  local vehId = rm.vehicleTracker:getVehicleId()
  local raceData = rm.raceData
  local raceState = raceData and raceData.states and raceData.states[vehId] or nil
  if raceState then
    drawPointSet(
      raceState.currentCorners,
      raceState.previousCorners,
      ColorF(1, 0.95, 0.1, 0.95),
      ColorF(1, 0.55, 0.05, 0.65),
      ColorF(1, 0.65, 0.05, 0.9),
      0.16,
      "race wheel hubs"
    )
  end

  local observer = rm.stageObserver
  if observer then
    drawPointSet(
      observer.currentCorners,
      observer.previousCorners,
      ColorF(0.05, 0.9, 1, 0.95),
      ColorF(0.05, 0.35, 1, 0.65),
      ColorF(0.05, 0.7, 1, 0.9),
      0.22
    )
  end
end

local function drawStageNextPathnode(rm)
  if not rm then return end
  local pathnodes = rm:getPathnodeObservationList()
  if not pathnodes then return end

  local observer = rm.stageObserver
  local startIdx = observer and observer.observationStartIndex or 1
  local nextPathnode = nil
  local nextIdx = nil

  for i = startIdx, #pathnodes do
    local pathnodeData = pathnodes[i]
    if pathnodeData and not pathnodeData.trackerObserved and not pathnodeData.trackerMissed then
      nextPathnode = pathnodeData
      nextIdx = i
      break
    end
  end

  if not nextPathnode then return end

  local pos = vec3(nextPathnode.pathnodePosX, nextPathnode.pathnodePosY, nextPathnode.pathnodePosZ)
  local radius = tonumber(nextPathnode.pathnodeRadius) or 1
  local isTiming = nextPathnode.isSplitTiming == true
  local shapeColor = isTiming and ColorF(0.1, 1.0, 0.25, 0.28) or ColorF(1.0, 0.9, 0.1, 0.22)
  local textBgColor = isTiming and ColorI(26, 255, 64, 220) or ColorI(255, 230, 26, 220)

  debugDrawer:drawSphere(pos, radius, shapeColor)

  if nextPathnode.pathnodeHasNormal then
    local normal = vec3(nextPathnode.pathnodeNormalX or 0, nextPathnode.pathnodeNormalY or 0, nextPathnode.pathnodeNormalZ or 0)
    debugDrawer:drawSquarePrism(
      pos,
      pos + 0.25 * normal,
      Point2F(5, radius * 2),
      Point2F(0, 0),
      isTiming and ColorF(0.1, 1.0, 0.25, 0.7) or ColorF(1.0, 0.9, 0.1, 0.55)
    )
  end

  local label = string.format(
    "next pathnode #%s %s [%s] %.1fm",
    tostring(nextIdx or '<none>'),
    tostring(nextPathnode.pathnodeName or '<unnamed>'),
    tostring(nextPathnode.pathnodeType or '<none>'),
    tonumber(nextPathnode.distFromStart) or -1
  )
  debugDrawer:drawTextAdvanced(
    pos + vec3(0, 0, 1.2),
    String(label),
    ColorF(0, 0, 0, 1),
    true,
    false,
    textBgColor,
    false,
    false
  )
end

function C:drawDebug()
  self:_updateVehiclePlacementMode()

  if self.debug.drawRacePath then
    local rm = self:getRallyManager()
    if rm then
      local rp = rm:getRacePath()
      if rp then
        rp:drawDebug('normal')
      end
    end
  end

  if self.debug.drawRaceSplits then
    local rm = self:getRallyManager()
    if rm then
      local dr = rm:getDrivelineRoute()
      local racePath = rm:getRacePath()
      local pathnodes = racePath and racePath.pathnodes and racePath.pathnodes.sorted or nil
      local routeStaticPath = dr and dr.routeStatic and dr.routeStatic.path or nil
      if pathnodes and routeStaticPath and routeStaticPath[1] then
        for i, pathnode in ipairs(pathnodes) do
          local point = pathnode:getStaticRoutePoint()
          if pathnode.useAsSplit and point then
            local startDistToFinish = routeStaticPath[1].distToTarget
            local distFromStart = startDistToFinish - point.distToTarget
            local distKm = distFromStart / 1000
            local pnType = point.metadata.racePathnodeType

            -- Get vehicle distance to this split
            local vehDistToFinish = dr.getTrackedDistToTarget and dr:getTrackedDistToTarget() or routeStaticPath[1].distToTarget
            local distToSplit = vehDistToFinish - point.distToTarget

            local distStr = string.format("%s %.2fkm | veh->%.1fm", pnType, distKm, distToSplit)
            -- local distStr = string.format("split %.8f", distFromStart)
            debugDrawer:drawTextAdvanced(point.pos, distStr, ColorF(0,0,0,1), true, false, ColorI(255,128,0,255), false, false)
          end
        end
      end
    end
  end

  if self.debug.drawRaceAiRoute then
    local rm = self:getRallyManager()
    local racePath = rm and rm.getRacePath and rm:getRacePath() or nil
    if racePath and racePath.drawAiRouteDebug then
      racePath:drawAiRouteDebug()
    end
  end

  if self.debug.drawVehicleTracker then
    local rm = self:getRallyManager()
    if rm and rm.vehicleTracker then
      rm.vehicleTracker:setDebugDraw(true)
    end
  else
    local rm = self:getRallyManager()
    if rm and rm.vehicleTracker then
      rm.vehicleTracker:setDebugDraw(false)
    end
  end

  if self.debug.drawStageTimingFootprints then
    drawStageTimingFootprints(self:getRallyManager())
  end

  if self.debug.drawStageNextPathnode then
    drawStageNextPathnode(self:getRallyManager())
  end

  if self.debug.drawRaceCurrentSeg then
    local race = self:getRace()
    local rm = self:getRallyManager()
    if rm and race then
      local currSegs = race.states[rm.vehicleTracker:getVehicleId()].currentSegments
      for i, segId in ipairs(currSegs) do
        local seg = race.path.segments.objects[segId]
        if seg and not seg.missing then
          local from = seg:getFrom()
          local to = seg:getTo()
          if from and to then
            local alpha = 0.3
            local fromName = from.name
            local toName = to.name

            if not from.useAsSplit then
              fromName = '('..fromName..')'
            end
            if not to.useAsSplit then
              toName = '('..toName..')'
            end

            local segClr = seg._rallyDebugColor
            local textFg = RallyUtil.getAppropriateTextColor(segClr)

            debugDrawer:drawSquarePrism(from.pos, to.pos, Point2F(2,4), Point2F(0,0), ColorF(segClr[1],segClr[2],segClr[3],alpha))
            debugDrawer:drawTextAdvanced(from.pos, String(string.format("%s [%s FROM]", fromName, seg.name)), textFg, true, false, ColorI(segClr[1]*255,segClr[2]*255,segClr[3]*255,255))
            debugDrawer:drawTextAdvanced(to.pos, String(string.format("%s [%s TO]", toName, seg.name)), textFg, true, false, ColorI(segClr[1]*255,segClr[2]*255,segClr[3]*255,255))

            -- debugDrawer:drawSphere(from.pos, from.radius, ColorF(1,0.5,0,alpha))
            -- debugDrawer:drawSphere(to.pos, to.radius, ColorF(1,0.5,0,alpha))

            local drawIntersectPlane = function(pn)
              if pn.hasNormal then
                local midWidth = pn.radius*2
                local side = pn.normal:cross(vec3(0,0,1)) *(pn.radius-pn.sidePadding.y - midWidth/2)
                -- debugDrawer:drawSquarePrism(
                --   pn.pos,
                --   (pn.pos + pn.radius * pn.normal),
                --   Point2F(1,pn.radius/2),
                --   Point2F(0,0),
                --   ColorF(1,0.5,0,alpha))
                debugDrawer:drawSquarePrism(
                  (pn.pos),
                  (pn.pos + 0.25 * pn.normal ),
                  Point2F(5,midWidth),
                  Point2F(0,0),
                  ColorF(segClr[1],segClr[2],segClr[3],alpha))
              end
            end
            drawIntersectPlane(from)
            drawIntersectPlane(to)
          end
        end
      end
    end
  end

  -- if self.debug.startPosition then
  --   local rp = self:getRallyManager():getRacePath()
  --   local defSpId = rp.defaultStartPosition
  --   local sp = rp.startPositions.objects[defSpId]
  --   if sp then

  --     sp:drawDebug()
  --   end
  -- end

  if self.debug.drawStartFinishLines then
    local rm = self:getRallyManager()
    if rm then
      local rp = rm:getRacePath()
      if rp then
        local defSpId = rp.defaultStartPosition
        local sp = rp.startPositions.objects[defSpId]
        local finish = rp.pathnodes.sorted[#rp.pathnodes.sorted]

        if sp then
          local midWidth = finish.radius*2 --- self.sidePadding.x - self.sidePadding.y

          local rot = sp.rot
          local normal = rot * vec3(0,-1,0) -- Forward vector from rotation

          -- log('D', logTag, 'start pos: '..dumps(sp.pos))

          debugDrawer:drawSquarePrism(
            sp.pos,
            (sp.pos + 0.25 * normal),
            Point2F(5,midWidth),
            Point2F(0,0),
            ColorF(1,0.5,0,0.6))
          debugDrawer:drawTextAdvanced(sp.pos,
            String('start'),
            ColorF(0,0,0,1), true, false,
            ColorI(255,128,0,255))
        end

        if finish then
          local midWidth = finish.radius*2 --- self.sidePadding.x - self.sidePadding.y
          -- local side = finish.normal:cross(vec3(0,0,1)) *(finish.radius-finish.sidePadding.y - midWidth/2)
          -- log('D', logTag, 'finish pos: '..dumps(finish.pos))
          -- local straightLineDist = finish.pos:distance(sp.pos)
          -- log('D', logTag, 'straight line dist: '..dumps(straightLineDist))
          debugDrawer:drawSquarePrism(
            finish.pos,
            (finish.pos + 0.25 * finish.normal ),
            Point2F(5,midWidth),
            Point2F(0,0),
            ColorF(1,0.5,0,0.6))
          debugDrawer:drawTextAdvanced(finish.pos,
            String('finish'),
            ColorF(0,0,0,1), true, false,
            ColorI(255,128,0,255))
        end
      end
    end
  end

  if self.debug.drawStopZone then
    local rp = self:getRallyManager():getRacePath()
    local spStopZone = nil
    for _, sp in ipairs(rp.startPositions.sorted) do
      if sp.name == "STOP_ZONE" or sp.name == "SS_stop_control" or sp.name == "TC_out" then
        spStopZone = sp
        break
      end
    end

    if spStopZone then
      debugDrawer:drawSphere(spStopZone.pos, 10, ColorF(1,0.5,0,0.5))
      debugDrawer:drawTextAdvanced(spStopZone.pos,
        String(spStopZone.name),
        ColorF(0,0,0,1), true, false,
        ColorI(255,128,0,255))
    end
  end

  if self.debug.drawNotebookPacenotes then
    local rm = self:getRallyManager()
    local dr = rm and rm:getDrivelineRoute()

    local function drawWp(wp, pacenoteName, pacenoteText, clr)
      local txtPos = vec3(wp.pos)
      local wpType = waypointTypes.shortenWaypointType(wp.waypointType)
      local clrFg = ColorF(0,0,0,1)
      local clrIBg = ColorI(clr[1] * 255, clr[2] * 255, clr[3] * 255, 255)
      debugDrawer:drawTextAdvanced(txtPos, String(string.format("%s[%s]%s", pacenoteName, wpType, pacenoteText)), clrFg, true, false, clrIBg)
    end

    if dr then
      for i, pacenote in ipairs(dr:getPacenotes()) do
        local pacenoteText = ''
        if true then
          pacenoteText = ' '..pacenote:noteOutputPreview()
        end
        drawWp(pacenote:getCornerStartWaypoint(), pacenote.name, pacenoteText, {0,1,0})
        drawWp(pacenote:getCornerEndWaypoint(), pacenote.name, pacenoteText, {1,0,0})
      end
    end
  end

    local monochrome = false
    if self.debug.drawRaceAiRoute then
      monochrome = true
    end
    local rm = self:getRallyManager()
    if rm then
      local nb = rm:getNotebookPath()
      local dr = rm:getDrivelineRoute()
      local static = self.debug.drawDrivelineRouteStatic
      if dr then
        local pacenoteCount = nb and nb.pacenotes and nb.pacenotes.sorted and #nb.pacenotes.sorted or 0
        dr:drawDebugDrivelineRoute(
          self.debug.drawDrivelineRoute,
          self.debug.drawRoutePacenotes,
          pacenoteCount * 2,
          monochrome,
          static,
          self.debug.drawRouteHiddenPathnodes,
          self.debug.drawRoutePathnodes,
          self.debug.drawRoutePointI,
          self.debug.drawRoutePointMetadata,
          self.debug.drawRoutePacenoteText
        )
      end
    end

  if self.debug.useMouseRayCast then
    local rm = self:getRallyManager()
    local dr = rm and rm:getDrivelineRoute()
    if dr then
      local pos = dr:getPosition()
      local speed = dr:getSpeed()
      if pos then
        debugDrawer:drawSphere(pos, 1.2, ColorF(0,0.5,0,0.8))
        if speed then
          debugDrawer:drawTextAdvanced(pos,
            String(string.format("%0.1f mph", speed * 2.23694)), -- convert m/s to mph
            ColorF(1,1,1,1), true, false,
            ColorI(0,127,0,255))
        end
      end
    end
  end

  -- if self.debug.drawPreRoutePoints then
  --   local dr = self:getRallyManager():getDrivelineRoute()
  --   local preRoutePoints = dr.debugPreRoutePoints
  --   if preRoutePoints then
  --     for i, point in ipairs(preRoutePoints) do
  --       local clr = rainbowColor(#preRoutePoints, i, 1)
  --     debugDrawer:drawSphere(point.pos, 1.2, ColorF(clr[1], clr[2], clr[3], 0.8))
  --     debugDrawer:drawTextAdvanced(point.pos,
  --       String(string.format("pre_%d", i)),
  --       ColorF(i < 10 and 1 or 0, i < 10 and 1 or 0, i < 10 and 1 or 0, 1), true, false,
  --       ColorI(clr[1] * 255, clr[2] * 255, clr[3] * 255, 255))
  --     end
  --   end
  -- end

  local rm = self:getRallyManager()
  if rm then
    local dr = rm:getDrivelineRoute()
    if self.debug.drawRouteNextPacenoteWpFromRecalc and dr and dr.nextPacenoteWpFromRecalc then
      local wpType = waypointTypes.shortenWaypointType(dr.nextPacenoteWpFromRecalc.waypointType)
      local pnName = dr.nextPacenoteWpFromRecalc.pacenote.name
      local wpRp = dr.nextPacenoteWpFromRecalc:getStaticRoutePoint()
      debugDrawer:drawSphere(wpRp.pos, 1.2, ColorF(1,1,0,0.8))
      debugDrawer:drawTextAdvanced(wpRp.pos,
        String(string.format("driveline.nextPacenoteWpFromRecalc: %s[%s]", pnName, wpType)),
        ColorF(0,0,0,1), true, false,
        ColorI(255,255,0,255))

      local pos = dr.lastRecalculateVehiclePos
      debugDrawer:drawSphere(pos, 1.2, ColorF(1,1,0,0.8))
      debugDrawer:drawTextAdvanced(pos,
        String(string.format("driveline.lastRecalculateVehiclePos")),
        ColorF(0,0,0,1), true, false,
        ColorI(255,255,0,255))

      local point = dr.debugNearestRecalcPoint
      if point then
        debugDrawer:drawSphere(point.pos, 1.2, ColorF(1,1,0,0.8))
        debugDrawer:drawTextAdvanced(point.pos,
          String(string.format("driveline.debugNearestRecalcPoint")),
          ColorF(0,0,0,1), true, false,
          ColorI(255,255,0,255))
      end

    end

    if self.debug.drawRouteNextRacePathnodeFromRecalc then
      local dr = rm:getDrivelineRoute()
      if dr and dr.nextRacePathnodeFromRecalc then
        local wpRp = dr.nextRacePathnodeFromRecalc:getStaticRoutePoint()
        debugDrawer:drawSphere(wpRp.pos, 1.2, ColorF(1,1,0,0.8))
        debugDrawer:drawTextAdvanced(wpRp.pos,
          String(string.format("driveline.nextRacePathnodeFromRecalc: %s", dr.nextRacePathnodeFromRecalc.name)),
          ColorF(0,0,0,1), true, false,
          ColorI(255,255,0,255))
      end
    end
  end

  if self.debug.drawRouteRecoveryTracker then
    local rm = self:getRallyManager()
    local dr = rm and rm:getDrivelineRoute()
    if dr and dr.setStaticTrackerDebugCapture then
      dr:setStaticTrackerDebugCapture(true)
    end
    local tracker = dr and dr.getStaticTrackerState and dr:getStaticTrackerState()
    if tracker then
      local function terrainDebugPos(pos, zOffset)
        local ret = vec3(pos)
        if core_terrain and core_terrain.getTerrain and core_terrain.getTerrain() then
          local terrainZ = core_terrain.getTerrainHeight(ret)
          if terrainZ and terrainZ > -100000 then
            ret.z = terrainZ
          end
        end
        ret.z = ret.z + (zOffset or 0.15)
        return ret
      end

      local path = dr.routeStatic and dr.routeStatic.path
      local corridorWidth = tonumber(tracker.offRouteDistance) or 0
      if path and tracker.segmentIdx and corridorWidth > 0 then
        local startIdx = math.max(1, tracker.segmentIdx - 12)
        local endIdx = math.min(#path, tracker.segmentIdx + 25)
        local leftPrev = nil
        local rightPrev = nil
        local corridorColor = ColorF(0.1, 0.8, 1, 0.55)

        local function segmentNormal(fromPoint, toPoint)
          if not fromPoint or not toPoint or not fromPoint.pos or not toPoint.pos then return nil end
          local dir = vec3(toPoint.pos) - vec3(fromPoint.pos)
          dir.z = 0
          if dir:length() <= 0 then return nil end
          dir:normalize()
          return vec3(-dir.y, dir.x, 0)
        end

        for i = startIdx, endIdx do
          local point = path[i]
          if point and point.pos then
            local prevNormal = segmentNormal(path[i - 1], point)
            local nextNormal = segmentNormal(point, path[i + 1])
            local side = nextNormal or prevNormal

            if prevNormal and nextNormal then
              side = prevNormal + nextNormal
              if side:length() <= 0 then
                side = nextNormal
              else
                side:normalize()
                local denom = math.max(math.abs(side:dot(nextNormal)), 0.35)
                side = side * math.min(corridorWidth / denom, corridorWidth * 2.5)
              end
            end

            if side and side:length() > 0 then
              if not (prevNormal and nextNormal) then
                side:normalize()
                side = side * corridorWidth
              end

              local center = vec3(point.pos)
              local left = terrainDebugPos(center + side, 0.15)
              local right = terrainDebugPos(center - side, 0.15)

              if leftPrev and rightPrev then
                debugDrawer:drawLineInstance(leftPrev, left, 2, corridorColor, false)
                debugDrawer:drawLineInstance(rightPrev, right, 2, corridorColor, false)
              end

              leftPrev = left
              rightPrev = right
            end
          end
        end
      end

      if tracker.routePos then
        local drawPos = terrainDebugPos(tracker.routePos, 0.25)
        debugDrawer:drawSphere(drawPos, 0.8, ColorF(0.1, 0.8, 1, 0.8))
        debugDrawer:drawTextAdvanced(drawPos,
          String(string.format("tracker %s %.1fm", tostring(tracker.state), tonumber(tracker.lateralDist) or -1)),
          ColorF(0,0,0,1), true, false,
          ColorI(26,204,255,220), false, false)
      end

      if tracker.departure and tracker.departure.routePos then
        local drawPos = terrainDebugPos(tracker.departure.routePos, 0.25)
        debugDrawer:drawSphere(drawPos, 1.0, ColorF(1, 0.45, 0, 0.8))
        debugDrawer:drawTextAdvanced(drawPos,
          String("route departure"),
          ColorF(0,0,0,1), true, false,
          ColorI(255,115,0,220), false, false)
      end

      if rm and rm.getRouteDepartureRecoveryPose then
        local recoveryPos = rm:getRouteDepartureRecoveryPose({
          backoffDistance = self.rallyRecoveryBackoffDistancePtr[0],
        })
        if recoveryPos then
          local drawPos = terrainDebugPos(recoveryPos, 0.25)
          debugDrawer:drawSphere(drawPos, 1.0, ColorF(0, 1, 0, 0.8))
          debugDrawer:drawTextAdvanced(drawPos,
            String("route recovery"),
            ColorF(0,0,0,1), true, false,
            ColorI(0,255,0,220), false, false)
        end
      end

      -- Diagnostic: TRUE local search window (distinct from wide corridor display range).
      do
        local firstIdx = tracker.window and tracker.window.firstIdx
        local lastIdx = tracker.window and tracker.window.lastIdx
        if (not firstIdx or not lastIdx) and tracker.segmentIdx then
          local behind = tonumber(tracker.searchBehind) or 4
          local ahead = tonumber(tracker.searchAhead) or 8
          firstIdx = math.max(1, tracker.segmentIdx - behind)
          lastIdx = tracker.segmentIdx + ahead
        end
        if path and firstIdx and lastIdx then
          firstIdx = math.max(1, firstIdx)
          lastIdx = math.min(#path, lastIdx)
          local windowColor = ColorF(1, 1, 0, 0.9)
          local prev = nil
          for i = firstIdx, lastIdx do
            local point = path[i]
            if point and point.pos then
              local cur = terrainDebugPos(point.pos, 0.3)
              if prev then
                debugDrawer:drawLineInstance(prev, cur, 4, windowColor, false)
              end
              prev = cur
            end
          end
          local startPoint = path[firstIdx]
          if startPoint and startPoint.pos then
            local drawPos = terrainDebugPos(startPoint.pos, 0.3)
            debugDrawer:drawSphere(drawPos, 0.5, windowColor)
            debugDrawer:drawTextAdvanced(drawPos,
              String("window start"),
              ColorF(0,0,0,1), true, false,
              ColorI(255,255,0,220), false, false)
          end
          local endPoint = path[lastIdx]
          if endPoint and endPoint.pos then
            local drawPos = terrainDebugPos(endPoint.pos, 0.3)
            debugDrawer:drawSphere(drawPos, 0.5, windowColor)
            debugDrawer:drawTextAdvanced(drawPos,
              String("window end"),
              ColorF(0,0,0,1), true, false,
              ColorI(255,255,0,220), false, false)
          end
        end
      end

      -- Diagnostic: local vs full projection candidates.
      if tracker.localCandidate and tracker.localCandidate.routePos then
        local c = tracker.localCandidate
        local drawPos = terrainDebugPos(c.routePos, 0.35)
        debugDrawer:drawSphere(drawPos, 0.6, ColorF(0, 1, 1, 0.85))
        debugDrawer:drawTextAdvanced(drawPos,
          String(string.format("local dTT=%.1f lat=%.1f", tonumber(c.distToTarget) or -1, tonumber(c.lateralDist) or -1)),
          ColorF(0,0,0,1), true, false,
          ColorI(0,255,255,220), false, false)
      end

      if tracker.fullCandidate and tracker.fullCandidate.routePos then
        local c = tracker.fullCandidate
        local drawPos = terrainDebugPos(c.routePos, 0.45)
        debugDrawer:drawSphere(drawPos, 0.6, ColorF(1, 0, 1, 0.85))
        debugDrawer:drawTextAdvanced(drawPos,
          String(string.format("full dTT=%.1f lat=%.1f", tonumber(c.distToTarget) or -1, tonumber(c.lateralDist) or -1)),
          ColorF(0,0,0,1), true, false,
          ColorI(255,0,255,220), false, false)
      end

      -- Diagnostic: persistent ring buffer of recent 'full' fallback events.
      self.debugFallbackEvents = self.debugFallbackEvents or {}
      local now = os.clock()
      if tracker.projectionSource == 'full' and tracker.fullCandidate and tracker.fullCandidate.routePos then
        local vehiclePos = dr.getPosition and dr:getPosition()
        table.insert(self.debugFallbackEvents, {
          vehiclePos = vehiclePos and vec3(vehiclePos) or nil,
          routePos = vec3(tracker.fullCandidate.routePos),
          t = now,
        })
        while #self.debugFallbackEvents > 8 do
          table.remove(self.debugFallbackEvents, 1)
        end
      end
      local fallbackTtl = 3.0
      for idx = #self.debugFallbackEvents, 1, -1 do
        local ev = self.debugFallbackEvents[idx]
        local age = now - (ev.t or now)
        if age > fallbackTtl then
          table.remove(self.debugFallbackEvents, idx)
        else
          local alpha = math.max(0.15, 1 - age / fallbackTtl)
          local routeDrawPos = terrainDebugPos(ev.routePos, 0.5)
          debugDrawer:drawSphere(routeDrawPos, 0.7, ColorF(1, 0, 0, alpha))
          if ev.vehiclePos then
            local vehDrawPos = terrainDebugPos(ev.vehiclePos, 0.5)
            debugDrawer:drawLineInstance(vehDrawPos, routeDrawPos, 3, ColorF(1, 0, 0, alpha), false)
          end
          debugDrawer:drawTextAdvanced(routeDrawPos,
            String("FULL FALLBACK"),
            ColorF(0,0,0,1), true, false,
            ColorI(255,0,0,math.floor(alpha * 220)), false, false)
        end
      end

    end
  elseif self.debug.lastDrawRouteRecoveryTrackerActive then
    -- Turn off the tracker's extra diagnostic projection when markers are hidden.
    local rm = self:getRallyManager()
    local dr = rm and rm:getDrivelineRoute()
    if dr and dr.setStaticTrackerDebugCapture then
      dr:setStaticTrackerDebugCapture(false)
    end
  end
  self.debug.lastDrawRouteRecoveryTrackerActive = self.debug.drawRouteRecoveryTracker

  if self.debug.drawRouteCompletion then
    local rm = self:getRallyManager()
    if rm then
      local dr = rm:getDrivelineRoute()
      if dr then
        local pos = dr:getPosition()
        local completionData = dr:getRaceCompletionData()
        if pos and completionData and completionData.distM and completionData.distPct then
          -- debugDrawer:drawTextAdvanced(pos,
          --   String(string.format("%dm", completionData.distM)),
          --   ColorF(1,1,1,1), true, false, ColorI(0,0,0,255))
          local dataStr = string.format("%.3fkm | %.1f%%", completionData.distM / 1000, completionData.distPct * 100)
          debugDrawer:drawTextAdvanced(pos,
            String(dataStr),
            ColorF(1,1,1,1), true, false, ColorI(0,0,0,255), false, false)
        end
      end
    end
  end

  if self.debug.drawRouteShort then
    local rm = self:getRallyManager()
    if rm then
      local dr = rm:getDrivelineRoute()
      if dr then
        dr:drawDebugDrivelineRouteShort(100)
      end
    end
  end

  if self.debug.drawReccePacenotes then
    local rm = self:getRallyManager()
    if rm then
      rm:drawPacenotesForDriving()
    end
  end

  if self.debug.drawDynamicTriggerPoint then
    local rm = self:getRallyManager()
    if rm then
      local dr = rm:getDrivelineRoute()
      if dr then
        dr:drawDebugTriggerPoint()
      end
    end
  end

  -- if self.debug.drawRecceDrivelinePoints then
    -- local rm = self:getRallyManager()
    -- if rm then
      -- local dr = rm:getDrivelineRoute()
      -- local reccePoints = nil
      -- if dr and dr.recordedDriveline then
        -- reccePoints = dr.recordedDriveline.points
      -- else
        -- self:loadReccePoints()
        -- if self.recce.driveline then
        --   reccePoints = self.recce.driveline.points
        -- end
      -- end
      -- if reccePoints then
        -- local clr = cc.snaproads_clr_recce
        -- for i, point in ipairs(reccePoints) do
          -- debugDrawer:drawCylinder(point.pos, point.pos + vec3(0,0,2), 0.3, ColorF(clr[1],clr[2],clr[3],0.8))
          -- debugDrawer:drawTextAdvanced(point.pos + vec3(0,0,2),
          --   String(string.format("recce_driveline_point_%d", i)),
          --   ColorF(1,1,1,1), true, false, ColorI(0,0,0,255))
          -- debugDrawer:drawSphere(point.pos, cc.snaproads_radius_recce, ColorF(clr[1], clr[2], clr[3], 0.8))
        -- end
      -- end
    -- end

    -- local finalPreRouteInput = dr.finalPreRouteInput
    -- for i, point in ipairs(finalPreRouteInput) do
    --   debugDrawer:drawCylinder(point.pos, point.pos + vec3(0,0,2), 0.1, ColorF(0.5,0,0.5,0.8))
    --   debugDrawer:drawTextAdvanced(point.pos + vec3(0,0,2),
    --     String(string.format("finalPreRouteInput_%d", i)),
    --     ColorF(1,1,1,1), true, false, ColorI(128,0,128,255))
    -- end

    -- local debugPreMergePath = dr.routeStatic.debugPath
    -- for i, point in ipairs(debugPreMergePath) do
    --   debugDrawer:drawCylinder(point.pos, point.pos + vec3(0,0,1.5), 0.2, ColorF(1,0.5,0.5,0.8))
    -- end

    -- local debugPostMergePath = dr.routeStatic.debugPostMergePath
    -- for i, point in ipairs(debugPostMergePath) do
    --   debugDrawer:drawCylinder(point.pos, point.pos + vec3(0,0,2), 0.1, ColorF(0,0.5,0.5,0.8))
    -- end

    -- local debugMergePathSample = dr.routeStatic.debugMergePathSample
    -- for i, point in ipairs(debugMergePathSample) do
    --   debugDrawer:drawCylinder(point.pos, point.pos + vec3(0,0,2), 0.1, ColorF(0,1,0.5,0.8))
    -- end

    -- local debugPostFixStartEnd1 = dr.routeStatic.debugPostFixStartEnd1
    -- for i, point in ipairs(debugPostFixStartEnd1) do
    --   debugDrawer:drawCylinder(point.pos, point.pos + vec3(0,0,2.5), 0.05, ColorF(1,1,0.5,0.8))
    -- end

    -- local debugPostFixStartEnd2 = dr.routeStatic.debugPostFixStartEnd2
    -- for i, point in ipairs(debugPostFixStartEnd2) do
    --   debugDrawer:drawCylinder(point.pos, point.pos + vec3(0,0,3.0), 0.025, ColorF(0.75,1,0.5,0.8))
    -- end

    -- if dr.routeStatic then
    --   local debugFixStartEnd_a = dr.routeStatic.debugFixStartEnd_a
    --   local debugFixStartEnd_b = dr.routeStatic.debugFixStartEnd_b
    --   local debugFixStartEnd_p = dr.routeStatic.debugFixStartEnd_p
    --   local debugFixStartEnd_xnorm = dr.routeStatic.debugFixStartEnd_xnorm

    --   if debugFixStartEnd_a and debugFixStartEnd_b and debugFixStartEnd_p then
    --     debugDrawer:drawCylinder(debugFixStartEnd_a.pos, debugFixStartEnd_a.pos + vec3(0,0,5.0), 0.01, ColorF(0,1,0,0.8))
    --     debugDrawer:drawCylinder(debugFixStartEnd_b.pos, debugFixStartEnd_b.pos + vec3(0,0,5.0), 0.01, ColorF(1,0,0,0.8))
    --     debugDrawer:drawCylinder(debugFixStartEnd_p.pos, debugFixStartEnd_p.pos + vec3(0,0,5.0), 0.01, ColorF(1,1,0,0.8))
    --     debugDrawer:drawTextAdvanced(debugFixStartEnd_p.pos,
    --       String(string.format("xnorm: %.2f", debugFixStartEnd_xnorm)),
    --       ColorF(0,0,0,1), true, false, ColorI(255,255,0,255))
    --   end
    -- end

  -- end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end