-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_traffic_trafficUtils'}
local kdTreeB2d = require('kdtreebox2d')
local maxPedestrians = 200
local kdT -- initialize in ignition function

local running = false
local gp = nil
local trafficSignals = nil
local objects = nil
local objectsN = 0
local OOBBTable = {}
local followCam = {false, nil}
local MAX_GARBAGE = 0
local MAX_TIME = 0
local MAX_TIME_BR = 0

--TODO: consolidate global params to a table to save upValue space, MAKE VECTOR TABLE for all temporary vec calcs
local testNode = "wpTown_6" --WCUSA default
local pedestrians = {} -- {pos, target, edge, side, speed, dir, step}
local pSpeed = 3
local pRadius = 0.25
local blueVec2d = vec3(0,0,0)
local blue = 0
local autoSpawnActive = false
local spawnTimer = 0

local downVec = vec3(0,0,-1)
local dir1, dir2, dir3, dir4 = vec3(0,0,0), vec3(0,0,0), vec3(0,0,0), vec3(0,0,0)
local aux = vec3(0,0,0)

-- vec3(-726.132, 108.871, 118.490)

------- for debugging
local debug = false
local stop = false
---------------------------------------------------------
local function activate()
  if gp == nil or not gp.graph or not next(gp.graph) then
    -- print("if gp == nil")
    gp = map.getGraphpath()
    if not gp or not gp.graph or not next(gp.graph) then print("no graphpath"); return end
  end

  if core_trafficSignals and trafficSignals == nil then
    trafficSignals = core_trafficSignals.getMapNodeSignals()
  end

  kdT = kdTreeB2d.new(maxPedestrians)
  if not running then running = true  end
end

local function visualizeRay(pos, dir, l, color)
  local d = pos + dir * l
  debugDrawer:drawCylinder(pos, d, 0.01, color)
  return d.x, d.y, d.z
end

local function getRayHitPos(pos, dir, l)
  aux:setScaled2(dir, l)
  aux:setAdd(pos)
  return aux.x, aux.y, aux.z
end

local function setSpeed(spd)
  pSpeed = spd
  print("New speed" ..spd.. ", default speed is 3")
end

local function makeOBB(id)
  local pd = pedestrians[id]
  pd.OBB[1]:setLerp(pd.pos, pd.head, 0.5) --c
  pd.OBB[2]:setScaled2(pd.dir, pRadius)
  pd.OBB[2]:setAdd(pd.OBB[1]) --x
  pd.OBB[3]:setScaled2(pd.rightVec, pRadius)
  pd.OBB[3]:setAdd(pd.OBB[1]) --y
  pd.OBB[4]:setScaled2(pd.heightVec, 0.5)
  pd.OBB[4]:setAdd(pd.OBB[1]) --z
end

local function populateOBBinRange()
  local i = 0
  for plID, o in pairs(objects) do
    local plOOBB = be:getObjectByID(plID)
    OOBBTable[i+1] = plOOBB:getBBCenter()
    -- Get bounding box direction vectors
    OOBBTable[i+2] = plOOBB:getDirectionVector() -- x
    OOBBTable[i+4] = plOOBB:getDirectionVectorUp() -- z
    OOBBTable[i+3] = OOBBTable[i+3] or vec3()
    OOBBTable[i+3]:setCross(OOBBTable[i+4], OOBBTable[i+2]); OOBBTable[i+3]:normalize() -- y (left)

    -- Scale bounding box direction vectors to vehicle dimensions
    OOBBTable[i+3]:setScaled(plOOBB:getInitialWidth() * 0.5)
    OOBBTable[i+2]:setScaled(plOOBB:getInitialLength() * 0.5)
    OOBBTable[i+4]:setScaled(plOOBB:getInitialHeight() * 0.5)
    i = i + 4
  end
end

local function castRay(rpos, rdir, rayDist, id)
  -- gcprobe()
  local carAhead = false
  -- dump("oobbtable size", #OOBBTable)
  for i = 1, #OOBBTable, 4 do
    local minHit, maxHit = intersectsRay_OBB(rpos, rdir, OOBBTable[i], OOBBTable[i+1], OOBBTable[i+2], OOBBTable[i+3])
    if maxHit > 0 then
      if rayDist > math.max(minHit, 0) then
        carAhead = true
      end
      rayDist = math.min(rayDist, math.max(minHit, 0))
    end
  end
  -- gcprobe()

  -- timeprobe()
  -- local hitsBrute = 0
  -- for i = 1,#pedestrians do
  --   if i ~= id and rpos:squaredDistance(pedestrians[i].raySource) < math.min(rayDist * rayDist, 16) then
  --     hitsBrute = hitsBrute + 1
  --     local minHit, maxHit = intersectsRay_Cylinder(rpos, rdir, pedestrians[i].pos, pedestrians[i].head, pRadius)
  --     -- local GARBAGE = gcprobe(nil, true)
  --     -- if MAX_GARBAGE < GARBAGE then dump("Max garbage", GARBAGE); MAX_GARBAGE = GARBAGE end
  --     if maxHit > 0 then
  --       if rayDist > math.max(minHit, 0) then
  --       end
  --       rayDist = math.min(rayDist, math.max(minHit, 0))
  --     end
  --   end
  -- end
  -- -- dump("after old iteration", timeprobe())
  -- local oldTime = timeprobe(true)
  -- timeprobe()

  -- local hits = 0
  -- local queryRange = math.min(rayDist, 4)
  -- for i in kdT:queryNotNested(rpos.x -queryRange, rpos.y-queryRange, rpos.x + queryRange, rpos.y + queryRange) do
  --   -- if not (pedestrians[i].raySource == rpos or pedestrians[i].raySourceRoaming == rpos) then
  --   if i ~= id and rpos:squaredDistance(pedestrians[i].raySource) < math.min(rayDist * rayDist, 16) then
  --     -- dump("i in kd", i)
  --     hits = hits + 1
  --     local minHit, maxHit = intersectsRay_Cylinder(rpos, rdir, pedestrians[i].pos, pedestrians[i].head, pRadius)
  --     rayDist = math.min(rayDist, math.max(minHit, 0))
  --   end
  -- end

  -- -- dump("after query", timeprobe())
  -- local kdTime = timeprobe(true)
  -- if id == 1 then dump("difference", kdTime - oldTime, (kdTime - oldTime) / oldTime, #pedestrians, hits, hitsBrute) end
  -- end
  -- gcprobe()

  for k, v in pairs(pedestrians[id].pedestriansInRange) do
    -- dump("test", pedestrians[id].pedestriansInRange, pedestrians[i].pos, pedestrians[i].head)
    -- gcprobe()
    -- local minHit, maxHit = intersectsRay_Cylinder(rpos, rdir, pedestrians[v].pos, pedestrians[v].head, pRadius)
    -- dump("cyl", gcprobe())
    -- gcprobe()
    local minHit, maxHit = intersectsRay_OBB(rpos, rdir, pedestrians[v].OBB[1], pedestrians[v].OBB[2], pedestrians[v].OBB[3], pedestrians[v].OBB[4])
    -- dump("obb", gcprobe())
    rayDist = math.min(rayDist, math.max(minHit, 0))
    pedestrians[id].pedestriansInRange[k] = nil

  end
  -- gcprobe()
  return castRayStatic(rpos, rdir, rayDist), carAhead
end

local function calculateTarget(edge, side) --TODO: test various inlcinations
  local target = gp.positions[edge[2]]:copy()
  local targetVec = target - gp.positions[edge[1]]
  local targetDir = targetVec:normalized()
  local perpendicularDir = targetDir:perpendicular()
  local targetNodeRadius = gp.radius[edge[2]]

  target:setAdd(-side * perpendicularDir * (targetNodeRadius*1.2 + 0.5)) -- x 1.1 etc is better
  target:setAdd(-targetDir * (targetNodeRadius*1.2 + 0.5))

  return target
end

local function pickRandomConnectingNode(nodeId) --TODO: Exclude drivability < 1
  if gp == nil or gp.graph[nodeId] == nil then return end
  local node = gp.graph[nodeId]
  local k = math.random(tableSize(node))
  local i = 1
  for n in pairs(node) do
    if i == k then
      return n
    end
    i = i + 1
  end
end

local function pickNextNodeNoCross(edge, side) --make crossing and side an argument. Problem when going on a dead end.
  local center = gp.positions[edge[2]]
  local a = gp.positions[edge[1]] - center
  a.z = 0
  -- a:normalize() -- not needed
  local max = math.pi
  local pick = nil

  for n, v in pairs(gp.graph[edge[2]]) do -- pick leftmost node when left atm.
    if n ~= edge[1] and v.drivability == 1 then --DRIVABILITY CHOICE TEST
      local b = gp.positions[n] - center
      b.z = 0
      -- b:normalize()
      local c = a:cross(b)
      local dot = a:dot(b)
      local pointer = math.atan2(-side * c.z, -dot)
      if pointer < max then
        pick = n
        max = pointer
      end
    end
  end
  if not pick then pick = edge[1]; side = -side end

  local center2 = gp.positions[pick]
  local pick2 = nil
  local a = gp.positions[edge[2]] - center2
  a.z = 0
  -- a:normalize()
  max = math.pi
  for n, v in pairs(gp.graph[pick]) do -- pick leftmost node when left atm.
    if n ~= edge[2] and v.drivability == 1 then --DRIVABILITY CHOICE TEST
      local b = gp.positions[n] - center2
      b.z = 0
      -- b:normalize()
      local c = a:cross(b)
      local dot = a:dot(b)
      local pointer = math.atan2(-side * c.z, -dot)
      if pointer < max then
        pick2 = n
        max = pointer
      end
    end
    if not pick2 then pick2 = edge[2] end
  end

  --Drawing turn line
  local streetVec1 = gp.positions[edge[2]]:z0() - center2:z0()
  -- streetVec1:z0()
  streetVec1:normalize()
  local streetVec2 = gp.positions[pick2]:z0() - center2:z0()
  -- streetVec2:z0()
  streetVec2:normalize()
  local b = lerp(streetVec1, streetVec2, 0.5)
  b:normalize()
  local turnLineAB = (center2 + b):z0() - center2:z0()
  if turnLineAB:squaredLength() == 0 then --when nodes are full straight
    turnLineAB = streetVec1:perpendicular():z0()
  end
  turnLineAB:normalize()
  return pick, turnLineAB, side
end

local function move(id, dt)
  -- gcprobe()
  -- correction for clipping in surface or floating
  --TODO can be done better probably
  local pd = pedestrians[id]
  -- local head = pd.pos + pHeightVec + pd.dir*0.3
  pd.head:setAdd2(pd.pos, pd.heightVec)
  makeOBB(id)

  local surfaceHeight = be:getSurfaceHeightBelow(pd.head)
  -- pd.pos:setLerp(pd.pos, vec3(pd.pos.x, pd.pos.y, surfaceHeight), 0.5)
  pd.pos:set(pd.pos.x, pd.pos.y, surfaceHeight)
  if pd.targetChanged then
    -- pd.tgtDir = gp.positions[pd.edge[2]] - gp.positions[pd.edge[1]]
    pd.tgtDir:setSub2(gp.positions[pd.edge[2]], gp.positions[pd.edge[1]])
    pd.tgtDir:normalize()
    pd.targetChanged = false
  end
  -- pd.step = pd.dir * (pd.speed or 1)
  pd.step:setScaled2(pd.dir, (pd.speed or 1) * dt)
  if debug then debugDrawer:drawCylinder(pd.head, pd.head + pd.dir*2, 0.1, ColorF(0,0,1,1)) end
  -- gcprobe()

  ----------------------FINDING OTHER PEDESTRIANS IN PROXIMITY-------------------------
  local hits = 0
  for i in kdT:queryNotNested(pd.pos.x - pd.awarenessRange, pd.pos.y - pd.awarenessRange, pd.pos.x + pd.awarenessRange, pd.pos.y + pd.awarenessRange) do
    if i ~= id and pd.pos:squaredDistance(pedestrians[i].raySource) < math.min(pd.awarenessRange * pd.awarenessRange, 16) then
      hits = hits + 1
      pd.pedestriansInRange[hits] = i
    end
  end
  ----------------------------------- SCANNING ----------------------------------------
  -- pd.rightVec:set(pd.dir:perpendicular()) --assuming that a pedestrian will always be straight up
  pd.rightVec:set(-pd.dir.y, pd.dir.x, 0)
  -- pd.rightVec.z = 0
  pd.rightVec:setScaled(-1)
  pd.rightVec:normalize()
  if debug then debugDrawer:drawCylinder(pd.pos, pd.pos + pd.rightVec, 0.1, ColorF(1,1,1,1)) end
  dir1:setLerp(pd.dir, pd.rightVec, 0.5) -- numbers here should be dependant on height
  dir1:normalize()
  dir1:setLerp(dir1, downVec, 0.5)
  dir1:normalize()
  dir2:setScaled2(pd.rightVec, -1)
  dir2:setLerp(pd.dir, dir2, 0.5)
  dir2:normalize()
  dir2:setLerp(dir2, downVec, 0.5)
  dir2:normalize()
  dir3:setLerp(pd.rightVec, downVec, 0.65)
  dir3:normalize()
  dir3:setLerp(dir3, dir1, 0.1)
  dir3:normalize()
  dir4:setScaled2(pd.rightVec, -1)
  dir4:setLerp(dir4, downVec, 0.65)
  dir3:normalize()
  dir4:setLerp(dir4, dir2, 0.1)
  dir4:normalize()
  if debug then
    debugDrawer:drawCylinder(pd.head, pd.head + dir1*4, 0.02, ColorF(1,1,1,1))
    debugDrawer:drawCylinder(pd.head, pd.head + dir2*4, 0.02, ColorF(1,1,1,1))
    debugDrawer:drawCylinder(pd.head, pd.head + dir3*4, 0.02, ColorF(1,1,1,1))
    debugDrawer:drawCylinder(pd.head, pd.head + dir4*4, 0.02, ColorF(1,1,1,1))
  end

  local areas = 2
  -- local vertexT = {}
  -- local triangleVertexVec = vec3()
  -- local triangleVertexVecHelper = vec3()
  -- local areaEndTop = vec3()
  -- local areaEndBottom = vec3()
  -- local areaStartTop = vec3()
  -- local areaStartBottom = vec3()

  local areaMiddleT = nil -- for debugging

  if debug then areaMiddleT = {} end

  -- table.clear(pd.sensors.vertexT)

  -- pd.dir:setScaled(pRadius * 1.2)
  pd.raySource:setScaled2(pd.dir, pRadius * 1.2)
  pd.raySource:setAdd(pd.head)
  -- timeprobe()
  -- gcprobe()
  for i=1,3 do

    blueVec2d:getBlueNoise2d()

    for j=1,areas do

      pd.sensors.areaStartTop:setLerp(dir1, dir2, (1/areas)*(j-1))
      pd.sensors.areaStartTop:normalize() -- The boundaries for "areas" vertical scanning areas in the total scanning rectangle
      pd.sensors.areaStartBottom:setLerp(dir3, dir4, (1/areas)*(j-1))
      pd.sensors.areaStartBottom:normalize()
      pd.sensors.areaEndTop:setLerp(dir1, dir2, (1/areas)*j)
      pd.sensors.areaEndTop:normalize() -- The boundaries for "areas"" vertical scanning areas in the total scanning rectangle
      pd.sensors.areaEndBottom:setLerp(dir3, dir4, (1/areas)*j)
      pd.sensors.areaEndBottom:normalize()

      -- ------ debug
      if debug then
        local midX1 = vec3()
        local midX2 = vec3()
        midX1:setLerp(pd.sensors.areaStartTop, pd.sensors.areaEndTop, 0.5)
        midX1:normalize()
        midX2:setLerp(pd.sensors.areaStartBottom, pd.sensors.areaEndBottom, 0.5)
        midX2:normalize()
        local midY = vec3()
        midY:setLerp(midX1, midX2, 0.2)
        local midRay = castRay(pd.raySource, midY, 100, id)
        local areaMidHitPos = vec3()
        areaMidHitPos:set(visualizeRay(pd.raySource, midY, midRay, ColorF(0,1,0,1)))
        table.insert(areaMiddleT, areaMidHitPos)
      end
            -- -------

      pd.sensors.triangleVertexVec:setLerp(pd.sensors.areaStartTop, pd.sensors.areaEndTop, blueVec2d.x)
      pd.sensors.triangleVertexVec:normalize()
      pd.sensors.triangleVertexVecHelper:setLerp(pd.sensors.areaStartBottom, pd.sensors.areaEndBottom, blueVec2d.x)
      pd.sensors.triangleVertexVecHelper:normalize()
      pd.sensors.triangleVertexVec:setLerp(pd.sensors.triangleVertexVec, pd.sensors.triangleVertexVecHelper, blueVec2d.y)
      pd.sensors.triangleVertexVec:normalize()

      -- gcprobe()
      local triangleRay = castRay(pd.raySource, pd.sensors.triangleVertexVec, 50, id)
      -- local GARBAGE = gcprobe(nil, true)
      -- if MAX_GARBAGE < GARBAGE then dump("Max garbage", GARBAGE); MAX_GARBAGE = GARBAGE end
      -- gcprobe()
      -- local vertexHitPos = visualizeRay(pd.raySource, pd.sensors.triangleVertexVec, triangleRay, ColorF(1,0,0,1))
      aux:set(getRayHitPos(pd.raySource, pd.sensors.triangleVertexVec, triangleRay)) -- , ColorF(1,0,0,1))
      if debug then visualizeRay(pd.raySource, pd.sensors.triangleVertexVec, triangleRay, ColorF(1,0,0,1)) end
      -- gcprobe()
      -- table.insert(pd.sensors.vertexT, aux:copy())
      if pd.sensors.vertexT[(i - 1) * areas + j] then
        pd.sensors.vertexT[(i - 1) * areas + j]:set(aux)
      else
        -- print("inserting")
        table.insert(pd.sensors.vertexT, aux:copy())
      end
      -- gcprobe()
    end
  end
  -- timeprobe()
  -- gcprobe() --------------------856 garbage

  -- local normals = {}
  -- local upVec = pd.dir:cross(pd.rightVec)
  aux:setCross(pd.rightVec, pd.dir) --upVec, garbage only on spawn
  -- aux:setScaled(-1)
  aux:normalize()
  if debug then debugDrawer:drawCylinder(pd.head, pd.head + aux*4, 0.02, ColorF(0.5,0.5,0.5,1)) end
  for i=1,areas do
    -- local normal = (pd.sensors.vertexT[i + areas] - pd.sensors.vertexT[i]):cross(pd.sensors.vertexT[i + areas * 2] - pd.sensors.vertexT[i]):normalized()
    dir1:setSub2(pd.sensors.vertexT[i + areas], pd.sensors.vertexT[i]) --finding the normal of triangle on ground
    dir2:setSub2(pd.sensors.vertexT[i + areas * 2], pd.sensors.vertexT[i])
    dir3:setCross(dir1, dir2)
    dir3:normalize()
    if dir3:dot(aux) < 0 then
      dir3:setScaled(-1)
    end
    if pd.samples == 0 or pd.samples == nil then
      table.insert(pd.normals, dir3:copy())
    else
      pd.normals[i]:set(dir3)
    end
    -- table.insert(normals, dir3:copy())

  end

  -- running average smoother with exponential weight
  if pd.samples == 0 or pd.samples == nil then
    -- print("Sampling starts")
    for i=1,areas do
      pd.smoothNormalsT[i] = aux:copy()
      pd.varianceSmootherT[i] = newExponentialSmoothing(2 * (1/dt), 1)

    end
    -- dump("Variance smoothers", pd.varianceSmootherT)
  end

  -- gcprobe()
  pd.samples = pd.samples + 1
  for i=1,areas do
    pd.smoothNormalsT[i]:setLerp(pd.smoothNormalsT[i], pd.normals[i], dt)
    pd.smoothNormalsT[i]:normalize()
    pd.varianceT[i] = pd.varianceSmootherT[i]:get(pd.smoothNormalsT[i]:dot(pd.normals[i]))
  end

  -- RAY IN front
  blue = getBlueNoise1d(blue)
  -- local rayPos = pd.raySource + downVec*1.5*blueVec2d.x --TODO:next optimization session
  local scale = blueVec2d.x*pd.heightVec.z*0.75
  pd.raySourceRoaming:setScaled2(downVec, scale)
  pd.raySourceRoaming:setAdd(pd.raySource)

  dir2:setScaled2(pd.rightVec, -0.35)
  dir3:setScaled2(pd.rightVec, 0.7*blueVec2d.y)
  dir2:setAdd(dir3)
  pd.raySourceRoaming:setAdd(dir2)

  -- dir2:setAdd(-0.35*pd.rightVec + 0.70*blueVec2d.y*pd.rightVec)
  local frontRay , carAhead = castRay(pd.raySourceRoaming, pd.dir, 4, id)
  -- dump(timeprobe(true) * #pedestrians)
  pd.carAhead = carAhead
  if debug then visualizeRay(pd.raySourceRoaming, pd.dir, frontRay, ColorF(1,0,0,1)) end

  -- TURN LOGIC

  -- gcprobe()
  if frontRay <= 2 then --something blocks, turn
    -- dump("Why does dir go downwards?", pd.dir, pd.rightVec)
    if pd.side == -1 then
      if pd.varianceT[1] - pd.varianceT[2] > 0.005 then
        pd.dir:setLerp(pd.dir, pd.rightVec, dt)
      else
        pd.dir:setLerp(pd.dir, -pd.rightVec, dt)
      end
    else
      if pd.varianceT[2] - pd.varianceT[1] > 0.005 then
        pd.dir:setLerp(pd.dir, -pd.rightVec, dt)
      else
        pd.dir:setLerp(pd.dir, pd.rightVec, dt)
      end
    end
    pd.dir:normalize()
    pd.speed = 0.4
    -- dump("dir and tgtdir after turn", pd.dir, pd.tgtDir)
  elseif pd.dir:dot(pd.tgtDir) < 0.99995 then
    -- dump("not looking at target")
    pd.dir:setLerp(pd.dir, pd.tgtDir, dt * 1.2)
    pd.dir:normalize()
    pd.speed = pSpeed*0.5
  else
    pd.speed = pSpeed
  end
  -- gcprobe()
  for i=1,areas,1 do
    if debug then
      visualizeRay(areaMiddleT[i], pd.smoothNormalsT[i], 2, ColorF(0,0,1,1))
      debugDrawer:drawText(areaMiddleT[i] + vec3(0,0,2), String("Variance: " .. pd.varianceT[i]), ColorF(1,0,0,1))

      debugDrawer:drawCylinder(pd.sensors.vertexT[i], pd.sensors.vertexT[i+areas], 0.01, ColorF(0, 0, 0, 1))
      debugDrawer:drawCylinder(pd.sensors.vertexT[i+areas], pd.sensors.vertexT[i+areas*2], 0.01, ColorF(0, 0, 0, 1))
      debugDrawer:drawCylinder(pd.sensors.vertexT[i+areas*2], pd.sensors.vertexT[i], 0.01, ColorF(0, 0, 0, 1))
    end
  end
  -- debugDrawer:drawCylinder(pd.sensors.vertexT[i], pd.sensors.vertexT[i+areas], 0.01, ColorF(0, 0, 0, 1))
  -- debugDrawer:drawCylinder(pd.sensors.vertexT[i+areas], pd.sensors.vertexT[i+areas*2], 0.01, ColorF(0, 0, 0, 1))
  -- debugDrawer:drawCylinder(pd.sensors.vertexT[i+areas*2], pd.sensors.vertexT[i], 0.01, ColorF(0, 0, 0, 1))
  --------------------------------------------------------------------------------------

  if pd.carAhead == false then
    pd.carAheadTimer = pd.carAheadTimer + 1 * dt
    if pd.carAheadTimer > 1 then
      pd.pos:setAdd(pd.step)
    end
  else
    pd.carAheadTimer = 0
  end


  ----------------------------------------- USE DISTANCE TO ROAD FOR Out of bounds problem?
  local distToMidRoad = pd.pos:distanceToLine(gp.positions[pd.edge[1]], gp.positions[pd.edge[2]]) --TODO: Square distance
  if distToMidRoad < math.max(gp.radius[pd.edge[1]], gp.radius[pd.edge[2]]) + 1.6 then--multiple use make var
    -- pd.pos:setAdd(-pd.rightVec*dt)
    -- if pd.side == -1 then
    --   pd.pos:setAdd(-pd.rightVec*dt*0.5)
    -- else
    --   pd.pos:setAdd(pd.rightVec*dt*0.5)
    -- end
    dir1:setScaled2(pd.rightVec, 0.5 * dt * pd.side)
    pd.pos:setAdd(dir1)
  end
  ---------------------------GARBAGE PROBLEM--------------------------------------------------------------
  dir1:set(gp.positions[pd.edge[2]].x, gp.positions[pd.edge[2]].y, 0)
  local flat1 = dir1
  dir2:set(pd.pos.x, pd.pos.y, 0)
  local flat2 = dir2
  dir3:setSub2(flat1, flat2)
  local pdVecToNode = dir3
  pdVecToNode:normalize()
  local mult = 2.5
  if debug then debugDrawer:drawSphere(gp.positions[pd.edge[2]], math.max(gp.radius[pd.edge[1]] * mult, gp.radius[pd.edge[2]] * mult), ColorF(1,0.5,1,0.05)) end
  -- local GARBAGE = gcprobe(nil, true)
  -- if MAX_GARBAGE < GARBAGE then dump("Max garbage", GARBAGE); MAX_GARBAGE = GARBAGE end
  -- gcptobe()
  if trafficSignals then
    -- for k,v in pairs(trafficSignals) do --TODO: n^2 can be done as 1, use hash
    --   if pd.edge[1] == k then
    --     for m,n in pairs(trafficSignals[k]) do
    --       if pd.edge[2] == m then
    --         pd.trafficLight = n[1].state
    --       end
    --     end
    --     break
    --   else
    --     pd.trafficLight = nil
    --   end
    -- end
    if trafficSignals[pd.edge[1]] and trafficSignals[pd.edge[1]][pd.edge[2]] and trafficSignals[pd.edge[1]][pd.edge[2]][1] then
      pd.trafficLight = trafficSignals[pd.edge[1]][pd.edge[2]][1].state
    else
      pd.trafficLight = nil
    end
  end
  local newTargetNode, turnLineAB
  -- gcprobe()
  if pd.justSpawned then

    if flat1:distance(flat2) < math.max(gp.radius[pd.edge[1]] * mult, gp.radius[pd.edge[2]] * mult) then
      newTargetNode, turnLineAB, pd.side = pickNextNodeNoCross(pd.edge, pd.side)
      pd.edge[1] = pd.edge[2]
      pd.edge[2] = newTargetNode
      pd.target = calculateTarget(pd.edge, pd.side)
      pd.targetChanged = true
      pd.turnLineAB = turnLineAB
      pd.justSpawned = false


    end

  elseif pd.trafficLight == "redTrafficLight" then
    if math.abs(pdVecToNode:dot(pd.turnLineAB)) > 0.995 then
      newTargetNode, turnLineAB, pd.side = pickNextNodeNoCross(pd.edge, -1*pd.side)
      -- dump("red light, side", pd.side)
      -- pd.side = -1*pd.side
      -- dump("red light, side 2", pd.side)
      pd.edge[1] = pd.edge[2]
      pd.edge[2] = newTargetNode
      pd.target = calculateTarget(pd.edge, pd.side)
      pd.targetChanged = true
      pd.turnLineAB = turnLineAB
    end

  else
    if math.abs(pdVecToNode:dot(pd.turnLineAB)) > 0.995 then --TODO:absolute
      newTargetNode, turnLineAB, pd.side = pickNextNodeNoCross(pd.edge, pd.side)
      pd.edge[1] = pd.edge[2]
      pd.edge[2] = newTargetNode
      pd.target = calculateTarget(pd.edge, pd.side)
      pd.targetChanged = true
      pd.turnLineAB = turnLineAB
    end
  end


  if debug then
    if not pd.justSpawned then debugDrawer:drawCylinder(gp.positions[pd.edge[2]], pd.pos, 0.05, ColorF(0,1,0,1)) end
    if not pd.justSpawned then debugDrawer:drawCylinder(gp.positions[pd.edge[2]], gp.positions[pd.edge[2]] + pd.turnLineAB, 0.05, ColorF(1,0,0,1)) end
  end

  --test drivability
  -- local drive = gp.graph[pd.edge[1]][pd.edge[2]].drivabilty

  -- gcprobe()
  -- if MAX_GARBAGE < GARBAGE then dump("Max garbage", GARBAGE); MAX_GARBAGE = GARBAGE end
end

local function followPedestrian(id)
  if pedestrians ~= nil then
    followCam[1] = true
    followCam[2] = id
  end
  return
end

local function stopFollow()
  followCam[1] = false
end

-- local function despawnAll()

local function despawn(id)
  if id == nil then
    -- for k in pairs(pedestrians) do
    --   pedestrians[k] = nil
    -- end
    table.clear(pedestrians)
    autoSpawnActive = false
  else
    table.remove(pedestrians, id)
    -- dump("pedestrian no." .. id .. "DESPAWNED")
  end
end

local function spawnOnNode(spawnNode, number) --TODO: Better randomization, make decision with pickNextNodeNoCross
  activate()
  number = number or 1
  -- local side = math.random() - 0.5
  -- side = side / math.abs(side)
  local side = sign2(math.random() - 0.5)
  local valid = false

  for _, v in pairs(gp.graph[spawnNode]) do
    if v.drivability == 1 then
      valid = true
      break
    end
  end
  if not valid then print("not a valid spawn"); return end

  for i = 1, number do

    local pos = gp.positions[spawnNode]:copy() -- mapData.nodes[spawnNode].pos:copy()
    -- for k, v in pairs(gp) do
    --   dump(k)
    -- end
    -- dump("positions", gp.positions)
    -- dump("graph", gp.graph)

    local targetNode = pickRandomConnectingNode(spawnNode)
    local target = gp.positions[targetNode]:copy()
    local targetVec = target - pos
    local targetDir = targetVec:normalized()
    local perpendicularDir = targetDir:perpendicular() --this aims left evidently
    local nodeRadius = gp.radius[spawnNode]
    local edge = {spawnNode, targetNode}
    local heightVec= vec3(0,0,1.5 + math.random() * 0.5)
    -- local side = -1
    -- if i%2 == 0 then --one left one right
    --   pos:setAdd(perpendicularDir * (nodeRadius + 2))
    -- else
    --   pos:setAdd(-perpendicularDir * (nodeRadius + 2))
    --   side = 1
    -- end
    pos:setAdd(-side * perpendicularDir * (nodeRadius + 2))
    side = -side

    target = calculateTarget(edge, side)

    pos:setAdd(targetDir * (nodeRadius + 2))

    table.insert(pedestrians, {
      pos = pos,
      head = pos + heightVec,
      OBB = {vec3(), vec3(), vec3(), vec3()}, -- testing
      raySource = pos + heightVec + targetDir *0.3,
      raySourceRoaming = vec3(0, 0, 0),
      heightVec = heightVec,
      target = target,
      edge = edge,
      side = -side,
      speed = 1,
      step = vec3(0,0,0),
      dir = targetDir,
      rightVec = vec3(),
      tgtDir = targetDir:copy(),
      desire = {0, 1, 0},
      awarenessRange = 4,
      pedestriansInRange = {},
      turnLineAB = nil,
      targetChanged = true,
      justSpawned = true,
      trafficLight = nil,
      crossingStreet = false,
      carAhead = false,
      carAheadTimer = 0,
      samples = 0,
      normals = {},
      smoothNormalsT = {},
      varianceSmootherT = {},
      varianceT = {},
      spawnNode = spawnNode,
      targetNode = targetNode,
      sensors = {vertexT = {}, triangleVertexVec = vec3(), triangleVertexVecHelper = vec3(), areaEndTop = vec3(), areaEndBottom = vec3(), areaStartTop = vec3(),
                areaStartBottom = vec3()}
    })
  end
  -- maxPedestrians = maxPedestrians + number

  return true
end

local function debugSwitch()
  debug = not debug
end

-- M.onUpdate = nil
local function onUpdate(dtReal, dtSim, dtRaw)
  if not running then return end

  local population = #pedestrians
  if autoSpawnActive then
    local camPos = core_camera.getPosition()
    local road = gameplay_traffic_trafficUtils.findSpawnPointOnRoute(camPos, core_camera.getForward(), 100, 400, 180)
    -- dump("road", road, core_camera.getPosition(), core_camera.getForward())
    spawnTimer = spawnTimer + dtSim
    local population = #pedestrians
    -- dump("pop", population)

    for i = 1, population do
      if pedestrians[i].pos:squaredDistance(camPos) > 300*300 then
        despawn(i)
        break
      end
    end

    if road and population < maxPedestrians and spawnTimer >= 0.5 and dtSim < 0.032 then -- FPS check
      spawnOnNode(road.n1)
      spawnTimer = 0
    end
  end

  population = #pedestrians

  if population == 0 then return end --deactivate()

  objects = map.objects
  -- dump(objects)
  if objectsN ~= #objects then
    objectsN = #objects
    populateOBBinRange() --no need for range so far
    -- dump(objects)
  end

  for i = 1, population do
    -- dump(pedestrians, pedestrians[i])
    debugDrawer:drawCylinder(pedestrians[i].pos, pedestrians[i].head, 0.2, ColorF(1,0.4,0,1))
    debugDrawer:drawText(pedestrians[i].head, String(i .. " " .. pedestrians[i].spawnNode .. " --> " .. pedestrians[i].targetNode .. "  " .. pedestrians[i].side), ColorF(0,0,0,1))
    if debug then debugDrawer:drawCylinder(pedestrians[i].target, pedestrians[i].target + vec3(0,0,20), 0.5, ColorF(0,0,0,1)) end
  end

  -- dump("pop", #pedestrians)

  -- gcprobe()
  -- timeprobeStart()
  kdT:clear()
  for i=1,population do
    local pd = pedestrians[i]
    kdT:preLoad(i, pd.raySource.x - pRadius, pd.raySource.y - pRadius, pd.raySource.x + pRadius, pd.raySource.y + pRadius)
  end
  kdT:build()
  -- gcprobe()
  for i=1,population do
    move(i, dtSim)
  end
  -- timeprobe()
  -- gcprobe()
  -- dump(population)


  if followCam[1] == true then
    local ped = pedestrians[followCam[2]]
    local pos = ped.pos - ped.dir + vec3(0,0,3)
    core_camera.setPosition(0, pos)
  end

  local targetObj = nil
  for _, o in pairs(map.objects) do
    targetObj = o
  end
end

local function setAutoSpawning(flag)
  autoSpawnActive = flag
  if autoSpawnActive then
    dump("auto spawn active", flag)
    activate()
  else
    -- deactivate()
  end
end

local function spawnPedestrians()
  setAutoSpawning(not autoSpawnActive)
end

M.onUpdate = onUpdate
M.setAutoSpawning = setAutoSpawning
M.spawnPedestrians = spawnPedestrians
M.spawnOnNode = spawnOnNode
M.despawn = despawn
M.followPedestrian = followPedestrian
M.stopFollow = stopFollow
M.setSpeed = setSpeed
M.debugSwitch = debugSwitch

return M
