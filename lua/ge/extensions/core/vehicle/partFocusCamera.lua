-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Drives the hidden partFocus camera mode from the parts menu.
--
-- The focus point comes from the nodes the selected parts own. Their positions are live, so the
-- framing follows the vehicle as it rotates, deforms, or drops the part on the ground.
-- Bounds are measured in the vehicle's own axes and refreshed at low frequency, while the box is
-- rebuilt in world space every frame so it stays glued to the vehicle.
-- Focus and release requests wait for the selection to rest before the camera moves, and the move
-- itself is a timed glide done by the camera mode.

local M = {}
M.dependencies = {"core_vehicle_configTarget"}

local fitFovDegrees = 35
local padding = 1.2
local minExtent = 0.15 -- parts held by a single node would otherwise collapse to a point
-- requests come from hovering a list, so sweeping across rows must not drag the view along
local settleDelay = 0.5
-- entering, leaving and gliding between parts
local transitionTime = 1.2
M.updateInterval = 0.1
M.debugDrawPivot = false -- marks the focus point at the box centre

local vehId = nil
local previousCam = nil
local focusPlayer = 0
local nodeIds = nil
local updateTimer = 0
local centre = vec3()
local localMin = vec3()
local localMax = vec3()
local vehPos = vec3()
local axisRight = vec3()
local axisFwd = vec3()
local axisUp = vec3()
local focusPoint = vec3()
local hasBBox = false

local lastFramedRadius = 0
local pendingZoomSteps = 0
local focusOffsetUp = 0
local distanceMultiplier = 1
local preserveDistance = false
local meshHalf = vec3()
local meshOffset = vec3()
local hasMeshBox = false
local meshBoundsCache = {}
local meshBoundsVehId = nil

local pendingRequest = nil
local pendingRelease = false
local pendingTimer = 0
local appliedRequest = nil -- what is framed now, so repeating it does not restart the wait
local retargetMode = nil -- 'snap', 'glide' or 'brisk', handed to the camera mode on its next update

local bboxLineColor = ColorF(1, 0.55, 0.1, 1)
local bboxPivotColor = ColorF(1, 0.55, 0.1, 0.85)
local p000, p100, p010, p110 = vec3(), vec3(), vec3(), vec3()
local p001, p101, p011, p111 = vec3(), vec3(), vec3(), vec3()

local function readVehicleAxes(veh)
  axisFwd:set(veh:getDirectionVectorXYZ())
  axisUp:set(veh:getDirectionVectorUpXYZ())
  axisRight:setCross(axisFwd, axisUp)
end

local function setCorner(out, x, y, z)
  out:set(vehPos.x + axisRight.x * x + axisFwd.x * y + axisUp.x * z,
          vehPos.y + axisRight.y * x + axisFwd.y * y + axisUp.y * z,
          vehPos.z + axisRight.z * x + axisFwd.z * y + axisUp.z * z)
end

-- rebuilds the world corners from the local bounds, so the box rotates and moves with the vehicle
local function updateWorldBox(veh)
  vehPos:set(veh:getPositionXYZ())
  readVehicleAxes(veh)
  local x0, y0, z0 = localMin.x, localMin.y, localMin.z
  local x1, y1, z1 = localMax.x, localMax.y, localMax.z
  setCorner(p000, x0, y0, z0); setCorner(p100, x1, y0, z0)
  setCorner(p010, x0, y1, z0); setCorner(p110, x1, y1, z0)
  setCorner(p001, x0, y0, z1); setCorner(p101, x1, y0, z1)
  setCorner(p011, x0, y1, z1); setCorner(p111, x1, y1, z1)
  setCorner(centre, (x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
end

local function drawBBox()
  debugDrawer:drawLine(p000, p100, bboxLineColor)
  debugDrawer:drawLine(p100, p110, bboxLineColor)
  debugDrawer:drawLine(p110, p010, bboxLineColor)
  debugDrawer:drawLine(p010, p000, bboxLineColor)
  debugDrawer:drawLine(p001, p101, bboxLineColor)
  debugDrawer:drawLine(p101, p111, bboxLineColor)
  debugDrawer:drawLine(p111, p011, bboxLineColor)
  debugDrawer:drawLine(p011, p001, bboxLineColor)
  debugDrawer:drawLine(p000, p001, bboxLineColor)
  debugDrawer:drawLine(p100, p101, bboxLineColor)
  debugDrawer:drawLine(p110, p111, bboxLineColor)
  debugDrawer:drawLine(p010, p011, bboxLineColor)
  if M.debugDrawPivot then
    debugDrawer:drawSphere(centre, 0.08, bboxPivotColor)
  end
end

-- Rest-pose bounds of one flexmesh in jbeam space. Scanning every vertex costs a few ms on a big
-- mesh, so the result is kept for as long as the vehicle lives.
local function getMeshBounds(veh, flexbody)
  local bounds = meshBoundsCache[flexbody.mesh]
  if bounds ~= nil then return bounds or nil end
  bounds = false
  local obj = flexbody.fid and veh:getFlexmesh(flexbody.fid)
  local count = obj and obj:getVertexCount() or 0
  if count > 0 then
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for i = 0, count - 1 do
      local p = obj:getInitVertexPos(i)
      if p.x < minX then minX = p.x end
      if p.y < minY then minY = p.y end
      if p.z < minZ then minZ = p.z end
      if p.x > maxX then maxX = p.x end
      if p.y > maxY then maxY = p.y end
      if p.z > maxZ then maxZ = p.z end
    end
    bounds = {minX, minY, minZ, maxX, maxY, maxZ}
  end
  meshBoundsCache[flexbody.mesh] = bounds
  return bounds or nil
end

-- A jbeam node cage sits inside the visual mesh, so sizing the box from nodes alone draws it too
-- small. The size therefore comes from the selected meshes, and the centre from the gap the mesh and
-- node boxes have at rest, which also re-centres parts located through the node group fallback.
-- jbeam axes reach the local axes as (-x, -y, z), because right and fwd are the negated jbeam ones.
local function measureMeshBox(veh, vdata, ids, selectedMeshes)
  local mMinX, mMinY, mMinZ = math.huge, math.huge, math.huge
  local mMaxX, mMaxY, mMaxZ = -math.huge, -math.huge, -math.huge
  for _, flexbody in pairs(vdata.flexbodies or {}) do
    if selectedMeshes[flexbody.mesh] then
      local b = getMeshBounds(veh, flexbody)
      if b then
        if b[1] < mMinX then mMinX = b[1] end
        if b[2] < mMinY then mMinY = b[2] end
        if b[3] < mMinZ then mMinZ = b[3] end
        if b[4] > mMaxX then mMaxX = b[4] end
        if b[5] > mMaxY then mMaxY = b[5] end
        if b[6] > mMaxZ then mMaxZ = b[6] end
      end
    end
  end
  if mMinX > mMaxX then return false end

  local nMinX, nMinY, nMinZ = math.huge, math.huge, math.huge
  local nMaxX, nMaxY, nMaxZ = -math.huge, -math.huge, -math.huge
  for i = 1, #ids do
    local node = vdata.nodes[ids[i]]
    local p = node and node.pos
    if p then
      if p.x < nMinX then nMinX = p.x end
      if p.y < nMinY then nMinY = p.y end
      if p.z < nMinZ then nMinZ = p.z end
      if p.x > nMaxX then nMaxX = p.x end
      if p.y > nMaxY then nMaxY = p.y end
      if p.z > nMaxZ then nMaxZ = p.z end
    end
  end
  if nMinX > nMaxX then return false end

  meshHalf:set((mMaxX - mMinX) * 0.5, (mMaxY - mMinY) * 0.5, (mMaxZ - mMinZ) * 0.5)
  meshOffset:set(-((mMinX + mMaxX) - (nMinX + nMaxX)) * 0.5,
                 -((mMinY + mMaxY) - (nMinY + nMaxY)) * 0.5,
                  ((mMinZ + mMaxZ) - (nMinZ + nMaxZ)) * 0.5)
  return true
end

-- The nodes a part owns locate it exactly. A flexbody's node group is a deformation binding that
-- reaches into the surrounding structure (the pickup fuel tank mesh binds 48 frame nodes), so it is
-- only good enough for parts that own no nodes at all, such as trim, bulbs and tires.
local function collectNodes(vdata, partNames, selectedMeshes)
  local parts = {}
  for partPath, selected in pairs(partNames) do
    if selected then parts[partPath] = true end
  end
  for _, entry in pairs(vdata.flexbodies or {}) do
    if entry.partPath and selectedMeshes[entry.mesh] then
      parts[entry.partPath] = true
    end
  end
  for _, entry in pairs(vdata.props or {}) do
    if entry.partPath and selectedMeshes[entry.mesh] then
      parts[entry.partPath] = true
    end
  end

  local seen = {}
  local ids = {}
  local located = {}
  for key, node in pairs(vdata.nodes or {}) do
    if type(node) == 'table' and node.partPath and parts[node.partPath] then
      local cid = node.cid or key
      if not seen[cid] then
        seen[cid] = true
        ids[#ids + 1] = cid
      end
      located[node.partPath] = true
    end
  end

  for _, flexbody in pairs(vdata.flexbodies or {}) do
    if selectedMeshes[flexbody.mesh] and flexbody.partPath and not located[flexbody.partPath] then
      for _, cid in ipairs(flexbody._group_nodes or {}) do
        if not seen[cid] then
          seen[cid] = true
          ids[#ids + 1] = cid
        end
      end
    end
  end

  if #ids == 0 then return nil end
  return ids
end

-- partFocus is global, so this goes through the player's camera context rather than setByName
local function setFocusCam(camName)
  core_camera.setContextCamera(core_camera.getContextIdForPlayer(focusPlayer), camName)
  core_camera.startCameraTransition(transitionTime, focusPlayer)
end

local function holdLastPose()
  nodeIds = nil
  updateTimer = 0
  hasBBox = false
  hasMeshBox = false
  appliedRequest = nil
end

local function applyFocus(request)
  local inVehId = request.vehId
  local veh = inVehId and getObjectByID(inVehId)
  if not veh then
    M.clear()
    return
  end

  local vData = extensions.core_vehicle_manager.getVehicleData(inVehId)
  local vdata = vData and vData.vdata
  if not vdata then
    holdLastPose()
    return
  end

  local selectedMeshes = request.selectedMeshes or {}
  local ids = collectNodes(vdata, request.partNames, selectedMeshes)
  if not ids then
    holdLastPose()
    return
  end

  if meshBoundsVehId ~= inVehId then
    table.clear(meshBoundsCache)
    meshBoundsVehId = inVehId
  end

  nodeIds = ids
  hasMeshBox = measureMeshBox(veh, vdata, ids, selectedMeshes)
  local cameraOptions = request.cameraOptions
  focusOffsetUp = tonumber(cameraOptions.focusOffsetUp) or 0
  preserveDistance = cameraOptions.preserveDistance == true
  local nextDistanceMultiplier = math.max(0.1, tonumber(cameraOptions.distanceMultiplier) or 1)
  if nextDistanceMultiplier ~= distanceMultiplier then lastFramedRadius = 0 end
  distanceMultiplier = nextDistanceMultiplier
  updateTimer = M.updateInterval
  if not vehId then
    focusPlayer = tonumber(request.playerId) or extensions.core_vehicle_configTarget.getTargetPlayerId() or 0
    previousCam = core_camera.getActiveCamName(focusPlayer)
    if previousCam == 'partFocus' then previousCam = nil end -- never restore ourselves, that latches the player in here
    setFocusCam('partFocus')
    pushActionMap("PartCamera") -- puts the mouse wheel on zoom for as long as we hold the camera
    retargetMode = 'snap' -- the global camera transition blends this one in
  else
    retargetMode = cameraOptions.immediate and 'brisk' or 'glide'
  end
  vehId = inVehId
  appliedRequest = request
end

local function sameParts(a, b)
  for k, v in pairs(a) do
    if v and not b[k] then return false end
  end
  for k, v in pairs(b) do
    if v and not a[k] then return false end
  end
  return true
end

local function sameRequest(a, b)
  if not a or not b then return false end
  local ao, bo = a.cameraOptions, b.cameraOptions
  return a.vehId == b.vehId and a.playerId == b.playerId
    and ao.focusOffsetUp == bo.focusOffsetUp
    and ao.distanceMultiplier == bo.distanceMultiplier
    and ao.preserveDistance == bo.preserveDistance
    and sameParts(a.partNames, b.partNames)
end

-- Callers repeat the same request on every hover update, some on every frame, so only a different
-- request restarts the wait. cameraOptions.immediate skips the wait, for moves the user asked for.
local function focusOnParts(inVehId, partNames, selectedMeshes, playerId, cameraOptions)
  cameraOptions = type(cameraOptions) == 'table' and cameraOptions or {}
  if type(partNames) ~= 'table' or not next(partNames) then
    M.release(cameraOptions.immediate == true)
    return
  end
  local request = {
    vehId = inVehId,
    partNames = partNames,
    selectedMeshes = selectedMeshes,
    playerId = playerId,
    cameraOptions = cameraOptions,
  }
  if cameraOptions.immediate then
    pendingRequest = nil
    pendingRelease = false
    if not sameRequest(request, appliedRequest) then applyFocus(request) end
    return
  end
  if sameRequest(request, pendingRequest) then return end
  pendingRelease = false
  if sameRequest(request, appliedRequest) then
    pendingRequest = nil
    return
  end
  pendingRequest = request
  pendingTimer = settleDelay
end

-- Hands the camera back to the player once the selection stays empty for settleDelay, or at once
-- when immediate.
function M.release(immediate)
  pendingRequest = nil
  if not vehId then return end
  if immediate then
    M.clear()
  elseif not pendingRelease then
    pendingRelease = true
    pendingTimer = settleDelay
  end
end

function M.clear()
  pendingRequest = nil
  pendingRelease = false
  retargetMode = nil
  holdLastPose()
  if vehId then
    vehId = nil
    lastFramedRadius = 0
    pendingZoomSteps = 0
    focusOffsetUp = 0
    distanceMultiplier = 1
    preserveDistance = false
    popActionMap("PartCamera")
  end

  -- always leave our own camera, even when we failed to record what was active before, and blend
  -- rather than cut: the part camera sits close in, so a hard switch is a violent jump
  if core_camera.getActiveCamName(focusPlayer) == 'partFocus' then
    setFocusCam(previousCam or 'orbit')
  end
  previousCam = nil
  focusPlayer = 0
end

-- node positions are relative to the vehicle, so projecting them on the vehicle axes gives bounds
-- in the vehicle's own coordinate system
local function refreshBounds(veh, cam)
  readVehicleAxes(veh)

  local minX, minY, minZ = math.huge, math.huge, math.huge
  local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
  for i = 1, #nodeIds do
    local px, py, pz = veh:getNodePositionXYZ(nodeIds[i])
    local x = px * axisRight.x + py * axisRight.y + pz * axisRight.z
    local y = px * axisFwd.x + py * axisFwd.y + pz * axisFwd.z
    local z = px * axisUp.x + py * axisUp.y + pz * axisUp.z
    if x < minX then minX = x end
    if y < minY then minY = y end
    if z < minZ then minZ = z end
    if x > maxX then maxX = x end
    if y > maxY then maxY = y end
    if z > maxZ then maxZ = z end
  end
  if minX > maxX then return end

  local cx, cy, cz = (minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5
  local halfX, halfY, halfZ = (maxX - minX) * 0.5, (maxY - minY) * 0.5, (maxZ - minZ) * 0.5
  if hasMeshBox then
    -- the live node centre carries the vehicle's motion and deformation, the mesh supplies the size
    cx, cy, cz = cx + meshOffset.x, cy + meshOffset.y, cz + meshOffset.z
    halfX, halfY, halfZ = meshHalf.x, meshHalf.y, meshHalf.z
  end
  halfX = math.max(halfX, minExtent * 0.5)
  halfY = math.max(halfY, minExtent * 0.5)
  halfZ = math.max(halfZ, minExtent * 0.5)
  localMin:set(cx - halfX, cy - halfY, cz - halfZ)
  localMax:set(cx + halfX, cy + halfY, cz + halfZ)
  hasBBox = true

  -- only reframe when the framing actually changes, otherwise the remeasure every updateInterval would
  -- keep undoing the player's zoom
  local radius = math.sqrt(halfX * halfX + halfY * halfY + halfZ * halfZ)
  if math.abs(radius - lastFramedRadius) > lastFramedRadius * 0.02 then
    lastFramedRadius = radius
    if cam and not preserveDistance then
      cam:setDefaultDistance(math.max(
        0.6,
        radius / math.tan(math.rad(fitFovDegrees * 0.5)) * padding * distanceMultiplier
      ))
    end
  end
end

-- The mouse wheel arrives as discrete notches through the PartCamera action map, unlike the zoom keys
-- which stay held, so the notches are banked here and applied as whole steps by the camera mode.
function M.isActive()
  return vehId ~= nil
end

function M.zoomStep(value)
  pendingZoomSteps = pendingZoomSteps + (tonumber(value) or 0)
end

function M.consumeZoomSteps()
  local steps = pendingZoomSteps
  pendingZoomSteps = 0
  return steps
end

-- The partFocus camera mode calls this from its own update instead of us running on the onUpdate hook:
-- node positions only settle in the physics step that luaPreRender follows, so reading them earlier
-- in the frame frames the part one step behind where it gets drawn.
function M.updateTarget(dt, cam)
  if not vehId or not nodeIds then return end

  local veh = getObjectByID(vehId)
  if not veh then return end

  if retargetMode and cam then
    cam:retarget(retargetMode == 'snap', transitionTime, retargetMode == 'brisk')
    retargetMode = nil
  end

  updateTimer = updateTimer + dt
  if updateTimer >= M.updateInterval then
    updateTimer = 0
    refreshBounds(veh, cam)
  end
  if not hasBBox then return end

  updateWorldBox(veh)
  drawBBox()
  if cam then
    focusPoint:set(
      centre.x + axisUp.x * focusOffsetUp,
      centre.y + axisUp.y * focusOffsetUp,
      centre.z + axisUp.z * focusOffsetUp
    )
    cam:setRef(focusPoint)
  end
end

-- dtReal: the vehicle configuration menu usually runs with the simulation paused
function M.onUpdate(dtReal)
  if not pendingRequest and not pendingRelease then return end
  pendingTimer = pendingTimer - dtReal
  if pendingTimer > 0 then return end
  if pendingRelease then
    M.clear()
    return
  end
  local request = pendingRequest
  pendingRequest = nil
  applyFocus(request)
end

function M.onVehicleResetted(resettedId)
  -- a reset teleports the part, so remeasure at once instead of letting the camera chase stale bounds
  if vehId == resettedId then
    updateTimer = M.updateInterval
  end
end

function M.onVehicleDestroyed(destroyedId)
  if vehId == destroyedId then
    M.clear()
  end
end

function M.onVehicleSpawned(spawnedId)
  if vehId == spawnedId then
    holdLastPose()
  end
end

function M.onVehicleSwitched(oldId, newId, player)
  if player == focusPlayer and vehId == oldId and oldId ~= newId then
    M.clear()
  end
end

function M.onVehicleConfigTargetChanged()
  M.clear()
end

M.focusOnParts = focusOnParts
M.onExtensionUnloaded = M.clear
M.onSerialize = M.clear

return M
