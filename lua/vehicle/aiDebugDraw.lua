-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local max, min, sqrt, abs = math.max, math.min, math.sqrt, math.abs
local strFormat = string.format

local ctx = nil
local bindContext = nil

local visDebug = {
  trajecRec = { last = 0 },
  routeRec = { last = 0 },
  labelRenderDistance = 10,
  candidatePaths = nil,
}

local function debugDraw(focusPos)
  local debugDrawer = obj.debugDrawProxy
  local scriptai = ctx.getScriptai()

  if ai.mode == 'script' and scriptai ~= nil then
    scriptai.debugDraw()
  end

  local currentRoute = ctx.getCurrentRoute()

  if currentRoute then
    local ego = ctx.ego
    local mapData = ctx.getMapData()
    local plan = currentRoute.plan
    local targetPos = plan.targetPos
    local targetSpeed = plan.targetSpeed

    if targetPos then
      debugDrawer:drawSphere(0.25, targetPos, color(255,0,0,255))

      local egoSeg = plan.egoSeg
      local shadowPos = currentRoute.plan[egoSeg].pos + plan.egoXnormOnSeg * (plan[egoSeg+1].pos - plan[egoSeg].pos)
      local blue = color(0,0,255,255)
      debugDrawer:drawSphere(0.25, shadowPos, blue)

      for vehId in pairs(mapmgr.getObjects()) do
        if vehId ~= objectId then
          debugDrawer:drawSphere(0.25, obj:getObjectFrontPosition(vehId), blue)
        end
      end

      local player = ctx.player()

      if player then
        debugDrawer:drawSphere(0.3, player.pos, color(0,255,0,255))
      end
    end

    if ai.debugMode == 'target' then
      if mapData and mapData.graph and currentRoute.path then
        local p = mapData.positions[currentRoute.path[#currentRoute.path]]
        debugDrawer:drawSphere(4, p, color(255,0,0,100))
        debugDrawer:drawText(p + vec3(0, 0, 4), color(0,0,0,255), 'Destination')
      end

    elseif ai.debugMode == 'route' then
      local maxCount = 700
      local last = visDebug.routeRec.last
      local count = min(#visDebug.routeRec, maxCount)
      if count == 0 or visDebug.routeRec[last]:squaredDistance(ego.pos) > 7 * 7 then
        last = 1 + last % maxCount
        visDebug.routeRec[last] = vec3(ego.pos)
        count = min(count+1, maxCount)
        visDebug.routeRec.last = last
      end

      local tmpVec = vec3(0.7, ego.width, 0.7)
      local black = color(0, 0, 0, 128)
      for i = 1, count-1 do
        debugDrawer:drawSquarePrism(visDebug.routeRec[1+(last+i-1)%count], visDebug.routeRec[1+(last+i)%count], tmpVec, tmpVec, black)
      end

      if currentRoute.plan[1].pathidx then
        local positions = mapData.positions
        local path = currentRoute.path
        tmpVec:setAdd(vec3(0, ego.width, 0))
        local transparentRed = color(255, 0, 0, 120)
        for i = currentRoute.plan[1].pathidx, #path - 1 do
          debugDrawer:drawSquarePrism(positions[path[i]], positions[path[i+1]], tmpVec, tmpVec, transparentRed)
        end
      end

      -- Draw candidate paths if available
      if visDebug.candidatePaths and visDebug.candidatePaths[1] then
        local winner = visDebug.candidatePaths.winner
        local source = visDebug.candidatePaths[1][1] -- all paths have the same source node
        debugDrawer:drawSphere(2, mapData.positions[source], color(0, 0, 0, 255))
        for i = 1, #visDebug.candidatePaths do
          local thisPath = visDebug.candidatePaths[i]
          local thisPathCount = #thisPath
          local thisScore = visDebug.candidatePaths[i].score
          for i = 1, thisPathCount-1 do
            debugDrawer:drawCylinder(mapData.positions[thisPath[i]], mapData.positions[thisPath[i+1]], 0.5, jetColor(thisScore, 200))
          end
          local thisPathLastNode = thisPath[thisPathCount]
          debugDrawer:drawSphere(4, mapData.positions[thisPathLastNode], jetColor(thisScore, 255))
          if thisPathLastNode == winner then
            debugDrawer:drawCylinder(mapData.positions[thisPathLastNode], mapData.positions[thisPathLastNode] + vec3(0, 0, 8), 2, color(0, 0, 0, 255))
          end
          local txt = thisPathLastNode.." -> "..strFormat("%0.4f", thisScore)
          debugDrawer:drawText(mapData.positions[thisPathLastNode] + vec3(0, 0, 2), color(0, 0, 0, 255), txt)
        end
      else
        -- Mark destination node in current path
        if currentRoute.path then
          local p = mapData.positions[currentRoute.path[#currentRoute.path]]
          debugDrawer:drawSphere(4, p, color(255, 0, 0, 100))
          debugDrawer:drawText(p + vec3(0, 0, 4), color(0, 0, 0, 255), 'Destination')
        end
      end

    elseif ai.debugMode == 'speeds' then
      -- Debug graph
      for k = 1, 2 do -- left and right plan
        -- Plot altPlan
        local altPlan = k == 1 and currentRoute.planL or currentRoute.planR
        if altPlan and plan.buildN then
          debugDrawer:drawSphere(0.1, altPlan.targetPos + vec3(0,0,0.5), color(0,255,255,255))
          for j = 1, altPlan.planCount do
            local point = altPlan[j]
            local speed = point.speed or 0
            debugDrawer:drawSphere(0.1, point.pos + vec3(0,0,0.5), color(255,255,255,255))
            debugDrawer:drawSphere(0.1, point.pos + vec3(0,0,speed*0.2), color(255,255,255,255))
            debugDrawer:drawText(point.pos + vec3(0,0,speed*0.2), color(0, 0, 0, 255), strFormat("%2.0f", speed*3.6).." kph")
            if j > 1 then
              local prevSpeed = altPlan[j-1].speed or 0
              debugDrawer:drawCylinder(altPlan[j-1].pos + vec3(0,0,0.5), point.pos + vec3(0,0,0.5), 0.05, color(255, 255, 255, 100))
              debugDrawer:drawCylinder(altPlan[j-1].pos + vec3(0,0,prevSpeed*0.2), point.pos + vec3(0,0,speed*0.2), 0.05, color(255*clamp(k-2, 0, 1), 255*clamp(k-1,0,1), 255, 100))
            end
          end
        end
      end

      -- Debug Throttle brake application
      local maxCount = 175
      local count = min(#visDebug.trajecRec, maxCount)
      local last = visDebug.trajecRec.last
      if count == 0 or visDebug.trajecRec[last][1]:squaredDistance(ego.pos) > (0.2 * 0.2) then
        last = 1 + last % maxCount
        visDebug.trajecRec[last] = {vec3(ego.pos), ego.speed, targetSpeed, ctx.lastCommand.brake, ctx.lastCommand.throttle}
        count = min(count+1, maxCount)
        visDebug.trajecRec.last = last
      end

      local tmpVec1 = vec3(0.7, ego.width, 0.7)
      for i = 1, count-1 do
        local n = visDebug.trajecRec[1 + (last + i) % count]
        debugDrawer:drawSquarePrism(visDebug.trajecRec[1 + (last + i - 1) % count][1], n[1], tmpVec1, tmpVec1, color(255 * sqrt(abs(n[4])), 255 * sqrt(n[5]), 0, 100))
      end

      local prevEntry
      local zOffSet = vec3(0, 0, 0.4)
      local yellow, blue = color(255,255,0,200), color(0,0,255,200)
      local tmpVec2 = vec3()
      for i = 1, count-1 do
        local v = visDebug.trajecRec[1 + (last + i - 1) % count]
        if prevEntry then
          -- actuall speed
          tmpVec1:set(0, 0, prevEntry[2] * 0.2)
          tmpVec2:set(0, 0, v[2] * 0.2)
          debugDrawer:drawCylinder(prevEntry[1] + tmpVec1, v[1] + tmpVec2, 0.02, yellow)

          -- target speed
          tmpVec1:set(0, 0, prevEntry[3] * 0.2)
          tmpVec2:set(0, 0, v[3] * 0.2)
          debugDrawer:drawCylinder(prevEntry[1] + tmpVec1, v[1] + tmpVec2, 0.02, blue)
        end

        tmpVec1:set(0, 0, v[3] * 0.2)
        debugDrawer:drawCylinder(v[1], v[1] + tmpVec1, 0.01, blue)

        if focusPos:squaredDistance(v[1]) < visDebug.labelRenderDistance * visDebug.labelRenderDistance then
          tmpVec1:set(0, 0, v[2] * 0.2)
          debugDrawer:drawText(v[1] + tmpVec1 + zOffSet, yellow, strFormat("%2.0f", v[2]*3.6).." kph")

          tmpVec1:set(0, 0, v[3] * 0.2)
          debugDrawer:drawText(v[1] + tmpVec1 + zOffSet, blue, strFormat("%2.0f", v[3]*3.6).." kph")
        end
        prevEntry = v
      end

      -- Planned speeds
      if plan[1] then
        local red = color(255,0,0,200) -- getContrastColor(objectId)
        local black = color(0, 0, 0, 255)
        local prevSpeed = -1
        local prevPoint = plan[1].pos
        local tmpVec = vec3()
        for i = 1, #plan do
          local n = plan[i]

          local speed = (n.speed >= 0 and n.speed) or prevSpeed
          tmpVec:set(0, 0, speed * 0.2)
          local p1 = n.pos + tmpVec
          debugDrawer:drawCylinder(n.pos, p1, 0.03, red)
          debugDrawer:drawCylinder(prevPoint, p1, 0.05, red)
          debugDrawer:drawText(p1, black, strFormat("%2.0f", speed*3.6).." kph")
          prevSpeed = speed
          prevPoint = p1


          --[[
          if traffic and traffic[i] then
            for _, data in ipairs(traffic[i]) do
              local plPosOnPlan = linePointFromXnorm(n.pos, plan[i+1].pos, data[2])
              debugDrawer:drawSphere(0.25, plPosOnPlan, color(0,255,0,100))
            end
          end
          --]]
        end

        ---[[ Debug road width and lane limits
        local prevPointOrig = plan[1].posOrig
        local tmpVec = vec3(1, 1, 1)
        local tmpVec1 = vec3(0.5, 0.5, 0.5)

        for i = 1, #plan do
          local n = plan[i]
          local p1Orig = n.posOrig - n.biNormal
          debugDrawer:drawCylinder(n.posOrig, p1Orig, 0.03, black)
          debugDrawer:drawCylinder(p1Orig, p1Orig + n.normal, 0.03, black)
          debugDrawer:drawCylinder(prevPointOrig, p1Orig, 0.03, black)
          local roadHalfWidth = n.halfWidth
          --debugDrawer:drawCylinder(n.posOrig, p1Orig, roadHalfWidth, color(255, 0, 0, 40))
          if n.laneLimLeft and n.laneLimRight then -- You need to uncomment the appropriate code in planAhead force integrator loop for this to work
            debugDrawer:drawSquarePrism(n.pos - (n.lateralXnorm - n.laneLimLeft) * n.normal, n.pos + (n.laneLimRight - n.lateralXnorm) * n.normal, tmpVec, tmpVec, color(0,0,255,120))
          end
          if n.rangeLeft and n.rangeRight then
            local rangeLeft = linearScale(n.rangeLeft, 0, 1, -roadHalfWidth, roadHalfWidth)
            local rangeRight = linearScale(n.rangeRight, 0, 1, -roadHalfWidth, roadHalfWidth)
            debugDrawer:drawSquarePrism(n.posOrig + rangeLeft * n.normal, n.posOrig + rangeRight * n.normal, tmpVec1, tmpVec1, color(255,0,0,120))
          end
          prevPointOrig = p1Orig
        end
        --]]

        --[[ Debug lane change. You need to uncomment upvalue newPositionsDebug for this to work
        if newPositionsDebug[1] then
          local green = color(0,255,0,200)
          local prevPoint = newPositionsDebug[1]
          for i = 1, #newPositionsDebug do
            local pos = newPositionsDebug[i]
            local p1 = pos + vec3(0, 0, 2)
            debugDrawer:drawCylinder(pos, p1, 0.03, green)
            debugDrawer:drawCylinder(prevPoint, p1, 0.05, green)
            prevPoint = p1
          end
        end
        --]]

        for i = max(1, plan[1].pathidx-2), #currentRoute.path-2 do
          local wp1 = currentRoute.path[i]
          local wp2 = currentRoute.path[i+1]
          if tableSize(mapData.graph[wp2]) > 2 then
            local minNode = ctx.roadNaturalContinuation(wp1, wp2)
            if minNode and minNode ~= currentRoute.path[i+2] then
              debugDrawer:drawCylinder(mapData.positions[wp2], mapData.positions[minNode], 0.2, black)
            end
          end
        end
      end

    elseif ai.debugMode == 'trajectory' then
      -- Debug Planned Speeds
      if plan[1] then
        local col = getContrastColor(objectId)
        local prevPoint = plan[1].pos
        local prevSpeed = -1
        local drawLen = 0
        for i = 1, #plan do
          local n = plan[i]
          local p = n.pos
          local v = (n.speed >= 0 and n.speed) or prevSpeed
          local p1 = p + vec3(0, 0, v*0.2)
          --debugDrawer:drawLine(p + vec3(0, 0, v*0.2), (n.pos + n.turnDir) + vec3(0, 0, v*0.2), col)
          debugDrawer:drawCylinder(p, p1, 0.03, col)
          debugDrawer:drawCylinder(prevPoint, p1, 0.05, col)
          debugDrawer:drawText(p1, color(0,0,0,255), strFormat("%2.0f", v*3.6) .. " kph")
          prevPoint = p1
          prevSpeed = v
          drawLen = drawLen + n.vec:length()
          if drawLen > 80 then break end
        end
      end

      -- Debug Throttle brake application
      local maxCount = 175
      local count = min(#visDebug.trajecRec, maxCount)
      local last = visDebug.trajecRec.last
      if count == 0 or visDebug.trajecRec[last][1]:squaredDistance(ego.pos) > 0.25 * 0.25 then
        last = 1 + last % maxCount
        visDebug.trajecRec[last] = {vec3(ego.pos), ctx.lastCommand.throttle, ctx.lastCommand.brake}
        count = min(count+1, maxCount)
        visDebug.trajecRec.last = last
      end

      local tmpVec = vec3(0.7, ego.width, 0.7)
      for i = 1, count-1 do
        local n = visDebug.trajecRec[1+(last+i)%count]
        debugDrawer:drawSquarePrism(visDebug.trajecRec[1+(last+i-1)%count][1], n[1], tmpVec, tmpVec, color(255 * sqrt(abs(n[3])), 255 * sqrt(n[2]), 0, 100))
      end
    elseif ai.debugMode == 'rays' then
      local egoScanLength = ego.length * 0.9 --small adjustments for origins to be a bit inside the car
      local egoScanWidth = ego.width * 0.7
      local shiftHorizontalVec = (egoScanWidth * 0.5) * ego.rightVec --creation of horizontal helper vector
      local shiftVerticalVec = -0.05 * ego.length * ego.dirVec --creation of vertical helper vector
      local shiftPerpendicularVec = 0.35 * ego.upVec
      local egoPosElevatedR = ego.pos:copy() --creation of FR corner vector
      egoPosElevatedR:setAdd(shiftHorizontalVec)
      egoPosElevatedR:setAdd(shiftVerticalVec)
      egoPosElevatedR:setAdd(shiftPerpendicularVec) -- elevation, this should work only on flat inclination for now
      local egoPosElevatedL = egoPosElevatedR:copy() --creation of FL corner vector
      shiftHorizontalVec:setScaled(-2)
      egoPosElevatedL:setAdd(shiftHorizontalVec)
      local egoPosBackElevatedL = egoPosElevatedL:copy() --creation of BR corner vector
      shiftVerticalVec:setScaled(egoScanLength * 20 / ego.length)
      egoPosBackElevatedL:setAdd(shiftVerticalVec)
      local egoPosBackElevatedR = egoPosElevatedR:copy() --creation of BL corner vector
      egoPosBackElevatedR:setAdd(shiftVerticalVec)

      local rayDist = 4 * ego.wheelBase -- TODO: Optimize rayDist. Higher is better for more open spaces but w performance hit
      ctx.populateOBBinRange(rayDist)
      local tmpVec = vec3()
      local helperVec = vec3()
      local rounds = ctx.twt.idx - 1
      dump("rounds in debug", rounds)

      for i = ctx.twt.idx, rounds do --the ray cast loop: each iteration scans one corner and one side
        i = i % 8 + 1
        local j = i * 4
        tmpVec:setLerp(ctx.twt.posTable[ctx.twt.RRT[j-3]], ctx.twt.posTable[ctx.twt.RRT[j-2]], ctx.twt.blueNoiseCoef)
        helperVec:setLerp(ctx.twt.dirTable[ctx.twt.RRT[j-1]], ctx.twt.dirTable[ctx.twt.RRT[j]], ctx.twt.blueNoiseCoef) -- LERP corner direction
        helperVec:normalize()
        local rayLen = castRay(tmpVec, helperVec, min(ctx.twt.rayMins[i], rayDist))

        local shiftVec = helperVec * rayLen
        local rayHitPos = tmpVec + shiftVec
        debugDrawer:drawCylinder(tmpVec, rayHitPos, 0.02, color(255,255,255,255))

        if ctx.twt.rayMins[i] > rayLen then -- odd index is corners
          ctx.twt.minRayCoefs[i] = ctx.twt.blueNoiseCoef
          ctx.twt.rayMins[i] = rayLen
        else
          tmpVec:setLerp(ctx.twt.posTable[ctx.twt.RRT[j-3]], ctx.twt.posTable[ctx.twt.RRT[j-2]], ctx.twt.minRayCoefs[i])
          helperVec:setLerp(ctx.twt.dirTable[ctx.twt.RRT[j-1]], ctx.twt.dirTable[ctx.twt.RRT[j]], ctx.twt.minRayCoefs[i]) -- LERP corner direction
          helperVec:normalize()
          ctx.twt.rayMins[i] = castRay(tmpVec, helperVec, min(2 * ctx.twt.rayMins[i], rayDist))
        end
      end

      debugDrawer:drawSphere(0.1, ctx.twt.posTable[1], color(255,255,255,255))
      debugDrawer:drawSphere(0.1, ctx.twt.posTable[2], color(255,255,255,255))
      debugDrawer:drawSphere(0.1, ctx.twt.posTable[3], color(255,255,255,255))
      debugDrawer:drawSphere(0.1, ctx.twt.posTable[4], color(255,255,255,255))

      for _, d in pairs(visDebug.debugSpots) do
        debugDrawer:drawSphere(0.2, d[1], d[2])
      end
    end
  end

  --[[
  if true then
    -- Draw vehicle ref node, wheel hub positions and wheel contact points (estimates) with ground
    local refNodePos = obj:getPosition()
    debugDrawer:drawSphere(0.1, refNodePos, color(255,0,0,255))
    for _, wheel in pairs(wheels.wheels) do
      local wheelRadius = wheel.radius
      local wheelPosAbsolute = refNodePos + obj:getNodePosition(wheel.node1)
      debugDrawer:drawSphere(0.1, wheelPosAbsolute, color(255,0,0,255))
      local contactPointPos = wheelPosAbsolute - obj:getDirectionVectorUp() * wheelRadius
      debugDrawer:drawSphere(0.1, contactPointPos, color(255,0,0,255))
    end

    -- vehicle frontPos
    local vehFrontPos = obj:getFrontPosition()
    debugDrawer:drawSphere(0.1, obj:getFrontPosition(), color(255, 255, 255, 255))
    -- vehicle frontPos
    debugDrawer:drawSphere(0.1, vehFrontPos:z0(), color(0, 255, 255, 255))

    -- calculated spawn pos (from script front pos)
    debugDrawer:drawSphere(0.1, vec3(736.8858419,102.6078886,0.1169999319), color(0, 0, 255, 255))

    -- script first pos (ground truth)
    debugDrawer:drawSphere(0.1, vec3(734.9434413112983, 102.21897064457461, 1.0), color(255, 0, 255, 255))

    -- Draw world reference Frame
    debugDrawer:drawSphere(0.1, vec3(0, 0, 0), color(0, 255, 0, 255)) -- World 0
    debugDrawer:drawCylinder(vec3(0, 0, 0), 5 * vec3(1, 0, 0), 0.05, color(0, 255, 0, 255)) -- x (green)
    debugDrawer:drawCylinder(vec3(0, 0, 0), 5 * vec3(0, 1, 0), 0.05, color(255, 0, 0, 255)) -- y (red)
    debugDrawer:drawCylinder(vec3(0, 0, 0), 5 * vec3(0, 0, 1), 0.05, color(0, 0, 255, 255)) -- z (blue)
  end
  --]]
end

function M.setContextBinder(fn)
  bindContext = fn
end

function M.init(context)
  ctx = context
end

function M.onDebugModeChanged(debugMode)
  if debugMode ~= 'trajectory' then
    table.clear(visDebug.trajecRec)
    visDebug.trajecRec.last = 0
  end
  if debugMode ~= 'route' then
    table.clear(visDebug.routeRec)
    visDebug.routeRec.last = 0
  end
  if debugMode ~= 'speeds' then
    table.clear(visDebug.trajecRec)
    visDebug.trajecRec.last = 0
  end
end

function M.reset()
  table.clear(visDebug.trajecRec)
  visDebug.trajecRec.last = 0
  table.clear(visDebug.routeRec)
  visDebug.routeRec.last = 0
end

function M.enable()
  if not ctx and bindContext then
    bindContext()
  end
  ai.debugDraw = debugDraw
end

function M.disable()
  ai.debugDraw = nop
end

return M
