-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local auditionHeight = 1000.0                                                                       -- The height above zero, at which the prefab groups are auditioned, in metres.
local camRotInc = math.pi / 500                                                                     -- The step size of the angle when rotating the camera around the audition center.
local auditionPlanarDistFac = 1.3                                                                   -- A factor used for determining the audition camera planar distance.
local auditionElevationFac = 0.4                                                                    -- A factor used for determining the audition camera elevation.
local prefabGroupFilepaths = {                                                                      -- A table of paths to the prefab group preset data files.
  { path = 'tech/PrefabGroups/crossroads_curb.json', name = 'Crossroads 4W [A]' },
  { path = 'tech/PrefabGroups/crossroads_var2.json', name = 'Crossroads 4W [B]' },
  { path = 'tech/PrefabGroups/bare_crossroads.json', name = 'Crossroads [Bare]' },
  { path = 'tech/PrefabGroups/crossroads_3W.json', name = 'T-Crossroads 3W' },
  { path = 'tech/PrefabGroups/x_jct_2way.json', name = 'X-Junction 4W | 1L' },
  { path = 'tech/PrefabGroups/t_junction.json', name = 'T-Junction 3W [A]' },
  { path = 'tech/PrefabGroups/t_jct_2way.json', name = 'T-Junction 3W [B]' },
  { path = 'tech/PrefabGroups/roundabout.json', name = 'Roundabout 4W' },
  { path = 'tech/PrefabGroups/RIRO_big.json', name = 'RIRO Intsct [A] 4W' },
  { path = 'tech/PrefabGroups/RIRO_4way.json', name = 'RIRO Intsct [B] 4W' },
  { path = 'tech/PrefabGroups/y_jct_street.json', name = 'Y-Jct Urban 3W' },
  { path = 'tech/PrefabGroups/road_island_sct.json', name = 'Road Island 2W' },
  { path = 'tech/PrefabGroups/jct_4_urban_A.json', name = 'Urban Int [A] 4W' },
  { path = 'tech/PrefabGroups/jct_4_urban_B.json', name = 'Urban Int [B] 4W' },
  { path = 'tech/PrefabGroups/trumpet.json', name = 'Trumpet Intsct' },
  { path = 'tech/PrefabGroups/diamond_4w.json', name = 'Diamond Int [B] 4W' }
}

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- External modules used.
local roadMgr = require('editor/tech/roadArchitect/roads')                                          -- A module for managing the road structure/handling road calculations.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                    -- A module for managing the profiles structure/handling profile calculations.

-- Private constants.
local im = ui_imgui
local min, max, sin, cos = math.min, math.max, math.sin, math.cos
local twoPi = math.pi * 2.0
local gView, auditionVec, auditionCamPos = vec3(0, 0), vec3(0, 0, auditionHeight), vec3(0, 0)
local tmp0, tmp1 = vec3(0, 0), vec3(0, 0)
local camRotAngle = 0.0
local isPOline = im.BoolPtr(true)                                                                   -- In auditioning, a flag which stores if road outlines are to be visible.
local isPLane = im.BoolPtr(true)                                                                    -- In auditioning, a flag which stores if lane info is to be visible.

-- Module state.
local groups = {}                                                                                   -- The array of prefab groups currently present in the editor.
local oldPos, oldRot = nil, nil                                                                     -- The previous camera pose, before going to profile view.
local isInGroupView = false                                                                         -- A flag which indicates if the camera is in group view, or not.


-- Copies a group road and elevates it to the audition pose.
local function elevateToAuditionPose(road)
  local nodes = road.nodes
  local numNodes = #nodes
  for i = 1, numNodes do
    local p = nodes[i].p
    nodes[i].p:set(p.x, p.y, p.z + auditionHeight)
  end
end

-- Computes the center and radius of the given group.
local function getCenterAndRadiusOfGroup(g)
  local m = g.roads
  local xMin, xMax, yMin, yMax, zMin, zMax, numMembers = 1e99, -1e99, 1e99, -1e99, 1e99, -1e99, #m
  for i = 1, numMembers do
    local nodes = m[i].nodes
    local numNodes = #nodes
    for j = 1, numNodes do
      local p = nodes[j].p
      local x, y, z = p.x, p.y, p.z
      xMin, xMax, yMin, yMax, zMin, zMax = min(xMin, x), max(xMax, x), min(yMin, y), max(yMax, y), min(zMin, z), max(zMax, z)
    end
  end
  tmp0:set(xMin, yMin, zMin)
  tmp1:set(xMax, yMax, zMax)
  local c = tmp0 + 0.5 * (tmp1 - tmp0)
  return c, tmp1:distance(c)
end

-- Updates the camera position upon changing of audition group.
local function updateCameraPose(gIdx)
  local _, r = getCenterAndRadiusOfGroup(groups[gIdx])
  gView:set(0.0, -r * auditionPlanarDistFac, auditionHeight + r * auditionElevationFac)
  local gRot = quatFromDir(auditionVec - gView)
  commands.setFreeCamera()
  core_camera.setPosRot(0, gView.x, gView.y, gView.z, gRot.x, gRot.y, gRot.z, gRot.w)
end

-- Rotate camera around the audition centroid.
local function rotateCamera(ang)
  local x, y, s, c = gView.x, gView.y, sin(ang), cos(ang)
  auditionCamPos:set(x * c - y * s, x * s + y * c, gView.z)
  local gRot = quatFromDir(auditionVec - auditionCamPos)
  core_camera.setPosRot(0, auditionCamPos.x, auditionCamPos.y, auditionCamPos.z, gRot.x, gRot.y, gRot.z, gRot.w)
end

-- Moves the camera to the prefab group preview pose.
-- [Also adjusts the timing parameters respectively].
local function goToGroupView(gIdx, timer, time)
  if not isInGroupView then
    time, isInGroupView = 0.0, true
    timer:stopAndReset()
    oldPos, oldRot = core_camera.getPosition(), core_camera.getQuat()                               -- Store the current camera position so we can return to it later.
    updateCameraPose(gIdx)                                                                          -- Move the camera to the audition pose for the selected group.
  end
  return time
end

-- Adds a prefab group to the roads container, so it will be rendered for the purpose of auditioning.
-- [Roads will be elevated to the audition pose and remain hidden in the roads array].
local function addGroupToRoadsAudition(gIdx)

  -- Compute the center of mass of the group.
  local group = groups[gIdx]
  local cen, _ = getCenterAndRadiusOfGroup(group)

  -- Do the non-link roads first.
  local groupRoads, roads = group.roads, roadMgr.roads
  local numRoads, ctr = #groupRoads, #roads + 1
  for i = 1, numRoads do
    local r = groupRoads[i]
    if not r.isLinkRoad then
      local rCopy = roadMgr.copyRoad(r)
      rCopy.isDisplayNodeSpheres = im.BoolPtr(false)
      rCopy.isDisplayRoadOutline = im.BoolPtr(isPOline[0])
      rCopy.isDisplayRefLine = im.BoolPtr(isPOline[0])
      rCopy.isDisplayLaneInfo = im.BoolPtr(isPLane[0])
      rCopy.isConformRoadToTerrain = im.BoolPtr(false)
      rCopy.isDirty = true
      local nodes = rCopy.nodes
      local numNodes = #nodes
      for j = 1, numNodes do
        nodes[j].p = nodes[j].p - cen
      end
      elevateToAuditionPose(rCopy)
      roads[ctr] = rCopy
      ctr = ctr + 1
    end
  end

  -- Now do the link roads.
  for i = 1, numRoads do
    local r = groupRoads[i]
    if r.isLinkRoad then
      local rCopy = roadMgr.copyRoad(r)
      rCopy.isDisplayNodeSpheres = im.BoolPtr(false)
      rCopy.isDisplayRoadOutline = im.BoolPtr(isPOline[0])
      rCopy.isDisplayRefLine = im.BoolPtr(isPOline[0])
      rCopy.isDisplayLaneInfo = im.BoolPtr(isPLane[0])
      rCopy.isConformRoadToTerrain = im.BoolPtr(false)
      rCopy.isDirty = true
      local nodes = rCopy.nodes
      local numNodes = #nodes
      for j = 1, numNodes do
        nodes[j].p = nodes[j].p - cen
      end
      elevateToAuditionPose(rCopy)
      roads[ctr] = rCopy
      ctr = ctr + 1
    end
  end

  -- Re-compute the road map.
  roadMgr.recomputeMap()

  -- Update the camera to fit the newly-selected group.
  -- [This is only done if we are already in the group view, since the old pos/rot have not been recorded yet].
  if isInGroupView then
    updateCameraPose(gIdx)
  end
end

-- Adds a prefab group to the roads container, so it will be rendered for the purpose of placement.
-- [The user has chosen this group, so the roads will not be elevated to the audition pose and will not be hidden].
-- [Unique name ids will be given to each profile and road in the group].
local function addGroupToRoadsPlace(gIdx, isConformGroupToTerrain)

  -- Do the non-link roads first.
  local groupRoads, roads = groups[gIdx].roads, roadMgr.roads
  local newRIds, numGroupRoads = {}, #groupRoads
  local firstRIdx = #roads + 1
  local ctr = firstRIdx
  for i = 1, numGroupRoads do
    local r = groupRoads[i]
    if not r.isLinkRoad then
      local rCopy = roadMgr.copyRoad(r)
      local idOld, idNew = rCopy.name, worldEditorCppApi.generateUUID()
      rCopy.name, newRIds[idOld], rCopy.isHidden = idNew, idNew, false
      if isConformGroupToTerrain then
        rCopy.isConformRoadToTerrain = im.BoolPtr(true)
      end
      roads[ctr] = rCopy
      ctr = ctr + 1
    end
  end

  -- Now do the link roads.
  for i = 1, numGroupRoads do
    local r = groupRoads[i]
    if r.isLinkRoad then
      local rCopy = roadMgr.copyRoad(r)
      local idOld, idNew = rCopy.name, worldEditorCppApi.generateUUID()
      rCopy.name, newRIds[idOld], rCopy.isHidden = idNew, idNew, false
      if isConformGroupToTerrain then
        rCopy.isConformRoadToTerrain = im.BoolPtr(true)
      end
      roads[ctr] = rCopy
      ctr = ctr + 1
    end
  end

  -- Update the road connectivity id data with the newly-generated id numbers.
  local pGroup, pCtr, lastRIdx = {}, 1, ctr - 1
  for i = firstRIdx, lastRIdx do
    local r = roads[i]
    r.startR, r.endR = newRIds[r.startR], newRIds[r.endR]
    local lS, lE = r.isLinkedToS, r.isLinkedToE
    local numLS, numLE = #lS, #lE
    for j = 1, numLS do
      lS[j] = newRIds[lS[j]]
    end
    for j = 1, numLE do
      lE[j] = newRIds[lE[j]]
    end
    pGroup[pCtr] = r.name
    pCtr = pCtr + 1
  end

  -- Re-compute the road map.
  roadMgr.recomputeMap()

  return pGroup
end

-- Manages the rotation of the audition camera.
local function manageRotateCam()
  rotateCamera(camRotAngle)
  camRotAngle = camRotAngle + camRotInc
  if camRotAngle > twoPi then
    camRotAngle = camRotAngle - twoPi
  end
end

-- Updates the visualisation properties for the audition roads.
local function changeAuditionMarkings()
  local roads = roadMgr.roads
  local numRoads = #roads
  for i = 1, numRoads do
    local r = roads[i]
    if r.isHidden then
      r.isDisplayRoadOutline = im.BoolPtr(isPOline[0])
      r.isDisplayRefLine = im.BoolPtr(isPOline[0])
      r.isDisplayLaneInfo = im.BoolPtr(isPLane[0])
    end
  end
end

-- Determines whether the given road is fully inside the given polygon.
local function isRoadExclusivelyInPolygon(r, polygon)
  local nodes = r.nodes
  local numNodes = #nodes
  for i = 1, numNodes do
    local p = nodes[i].p
    tmp0:set(p.x, p.y, 0.0)
    if not tmp0:inPolygon(polygon) then
      return false
    end
  end
  return true
end

-- Updates the road connectivity id data with the newly-generated id numbers.
local function updateConnectivityData(gRoads, rMap)
  local numGRoads = #gRoads
  for i = 1, numGRoads do
    local r = gRoads[i]
    if rMap[r.startR] then
      r.startR = rMap[r.startR]
    end
    if rMap[r.endR] then
      r.endR = rMap[r.endR]
    end
    local lS, lE = r.isLinkedToS, r.isLinkedToE
    local numLS, numLE = #lS, #lE
    for j = 1, numLS do
      if rMap[lS[j]] then
        lS[j] = rMap[lS[j]]
      end
    end
    for j = 1, numLE do
      if rMap[lE[j]] then
        lE[j] = rMap[lE[j]]
      end
    end
  end
end

-- Identifies group (from given polygon) and creates a new prefab group.
local function createGroup(gPolygon, roads)

  -- Convert the polygon to 2D.
  local polyLen = #gPolygon
  for i = 1, polyLen do
    local p = gPolygon[i]
    gPolygon[i]:set(p.x, p.y, 0.0)
  end

  -- Collect all the roads which are exclusively within the polygon.
  local gRoads, ctr, rMap, numRoads = {}, 1, {}, #roads
  for i = 1, numRoads do
    local r = roads[i]
    if isRoadExclusivelyInPolygon(r, gPolygon) and #r.nodes > 1 then
      gRoads[ctr] = roadMgr.copyRoad(r)
      local oldRId, newRId = gRoads[ctr].name, worldEditorCppApi.generateUUID()
      gRoads[ctr].name, gRoads[ctr].isHidden = newRId, true
      roadMgr.setDirty(gRoads[ctr])
      rMap[oldRId] = newRId
      ctr = ctr + 1
    end
  end

  -- Update the road connectivity id data with the newly-generated id numbers.
  updateConnectivityData(gRoads, rMap)

  -- Create the group, as long as there is at least one road present.
  if #gRoads > 0 then
    local gIdx = #groups + 1
    groups[gIdx] = { name = 'User ' .. tostring(gIdx), roads = gRoads }
  end
end

-- Creates a unique group from a data file.
local function importGroup(roads, name)

  -- Copy the road and profile, and add it to the new group.
  local gRoads, rMap, numRoads = {}, {}, #roads
  for i = 1, numRoads do
    local r = roads[i]
    gRoads[i] = roadMgr.copyRoad(r)
    local oldRId, newRId = gRoads[i].name, worldEditorCppApi.generateUUID()
    gRoads[i].name, gRoads[i].isHidden = newRId, true
    roadMgr.setDirty(gRoads[i])
    rMap[oldRId] = newRId
  end

  -- Update the road connectivity id data with the newly-generated id numbers.
  updateConnectivityData(gRoads, rMap)

  -- Create the group, as long as there is at least one road present.
  if #gRoads > 0 then
    local gIdx = #groups + 1
    local gName = name or 'User ' .. tostring(gIdx)
    groups[gIdx] = { name = gName, roads = gRoads }
  end
end

-- Returns the camera to the stored old view.
local function goToOldView()
  if oldPos and oldRot then
    core_camera.setPosRot(0, oldPos.x, oldPos.y, oldPos.z, oldRot.x, oldRot.y, oldRot.z, oldRot.w)
  end
  isInGroupView = false
end

-- Serialises a prefab group.
local function serialiseGroup(g)
  local gSer, r = { name = g.name, roads = {} }, g.roads
  local numRoads = #r
  for i = 1, numRoads do
    gSer.roads[i] = roadMgr.serialiseRoad(r[i])
  end
  return gSer
end

-- De-serialises a prefab group.
local function deserialiseGroup(gSer)
  local g, rSer = { name = gSer.name, roads = {} }, gSer.roads
  local numRoads = #rSer
  for i = 1, numRoads do
    g.roads[i] = roadMgr.deserialiseRoad(rSer[i])
  end
  return g
end

-- Saves the collection of current prefab groups to disk.
local function save(idx)
  extensions.editor_fileDialog.saveFile(
    function(data)
      local encodedData = { data = lpack.encode({ group = serialiseGroup(groups[idx]) })}
      jsonWriteFile(data.filepath, encodedData, true)
    end,
    {{"JSON",".json"}},
    false,
    "/",
    "File already exists.\nDo you want to overwrite the file?")
end

-- Loads a collection of current prefab groups from disk.
local function load()
  extensions.editor_fileDialog.openFile(
    function(data)
      local loadedJson = jsonReadFile(data.filepath)
      local data = lpack.decode(loadedJson.data)
      local gSer = deserialiseGroup(data.group)
      importGroup(gSer.roads)
    end,
    {{"JSON",".json"}},
    false,
    "/")
end

-- Populates the collection of default prefab groups, from the corresponding data files.
local function getDefaultGroups()
  if #groups > 0 then                                                                               -- If there are groups already there, do nothing.
    return
  end

  local numDefaultGroups = #prefabGroupFilepaths
  for i = 1, numDefaultGroups do
    local g = prefabGroupFilepaths[i]
    local loadedJson = jsonReadFile(g.path)
    local data = lpack.decode(loadedJson.data)
    local gSer = deserialiseGroup(data.group)
    importGroup(gSer.roads, g.name)
  end
end


-- Public interface.
M.groups =                                                groups
M.isPOline =                                              isPOline
M.isPLane =                                               isPLane

M.addGroupToRoadsAudition =                               addGroupToRoadsAudition
M.addGroupToRoadsPlace =                                  addGroupToRoadsPlace
M.goToGroupView =                                         goToGroupView
M.manageRotateCam =                                       manageRotateCam
M.changeAuditionMarkings =                                changeAuditionMarkings
M.createGroup =                                           createGroup
M.goToOldView =                                           goToOldView
M.serialiseGroup =                                        serialiseGroup
M.deserialiseGroup =                                      deserialiseGroup
M.save =                                                  save
M.load =                                                  load
M.getDefaultGroups =                                      getDefaultGroups

return M