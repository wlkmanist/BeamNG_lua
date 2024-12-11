-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Well hello there. All the code below is in a *really early* work-in-progress state, since it's just a brief incursion in my spare time. It will likely end up fully replaced, or abandoned, depending on time constraints, on other blocking tasks, etc. So best if you assume this will lead nowhere in the foreseeable future - stenyak

local M = {}

local debug = true

-- from the 3 points, assume they form a circle, and return:
--   - distance from p1 to p2
--   - distance from p2 to p3
--   - circle center
--   - circle angle covered by the points
local function circleDist1Dist2CenterAngleFromPoints(p1, p2, p3)
  local d1 = p1 - p3
  local d2 = p2 - p3
  local asql = d1:squaredLength()
  local bsql = d2:squaredLength()
  local adotb = d1:dot(d2)

  -- calculate lengths
  local d1l = math.sqrt(asql)
  local d2l = math.sqrt(bsql)

  -- calculate center
  local condVec = d1:cross(d2)
  local condVecSqLen = condVec:squaredLength()
  local center = p3 + ((bsql * (asql - adotb)) * d1 - (asql * (adotb - bsql)) * d2) / (2 * condVecSqLen + 1e-30), math.sqrt(condVecSqLen)

  -- calculate angle
  local angleCos = adotb / (d1l*d2l + 1e-30)
  local angleRad = math.acos(clamp(angleCos, -1, 1))
  local angle = math.deg(angleRad)*2

  return d1, d2, d1l, d2l, center, angle
end

local ci = ColorI(0,0,0,0)
local function temporaryColorI(color)
  ci.r, ci.g, ci.b, ci.a = math.floor(color.r*255), math.floor(color.g*255), math.floor(color.b*255), math.floor(color.a*255)
  return ci
end

local green = ColorF(0.1, 0.9, 0.1, 0.6)
local blue = ColorF(0.1, 0.1, 0.9, 0.6)
local grey = ColorF(0.5, 0.5, 0.5, 1.0)
local black = ColorF(0.0, 0.0, 0.0, 1.0)
local red = ColorF(0.9, 0.1, 0.1, 0.6)
local yellow = ColorF(0.9, 0.9, 0.1, 0.6)
local white = ColorF(1.0, 1.0, 1.0, 1.0)

local darkgreen  = ColorF(0.15, 0.73, 0.15, 1.0)
local darkorange = ColorF(1.00, 0.45, 0.00, 1.0)
local darkred    = ColorF(0.85, 0.00, 0.00, 1.0)
local darkviolet = ColorF(0.58, 0.00, 0.83, 1.0)
local darkcyan   = ColorF(0.00, 0.85, 0.95, 1.0)
local darkblue   = ColorF(0.36, 0.55, 0.80, 1.0)

local inf = 1/0
local severities = { }
table.insert(severities, {name="Hairpin" , velmax=50 , color=darkviolet, name2="square", name3="Slow" })
table.insert(severities, {name="Medium"  , velmax=70 , color=darkred    })
table.insert(severities, {name="Fast"    , velmax=100, color=darkorange })
table.insert(severities, {name="Easy"    , velmax=130, color=darkgreen  })
table.insert(severities, {name="Flat"    , velmax=170, color=darkblue   })
table.insert(severities, {name="Straight", velmax=inf, color=white      })
local severities = { }
table.insert(severities, {name="Hairpin", velmax=50 , color=darkviolet, name2="K", name3="Slow" })
table.insert(severities, {name="2",       velmax=80 , color=darkred    })
table.insert(severities, {name="3",       velmax=110, color=darkorange })
table.insert(severities, {name="4",       velmax=150, color=darkgreen  })
table.insert(severities, {name="5",       velmax=200, color=darkcyan   })
table.insert(severities, {name="6",       velmax=300, color=darkblue   })
table.insert(severities, {name="",        velmax=inf, color=white      })
local tightestId = 1
local slowId = 2
local straightId = #severities


local function getTurnVelocityWithSlickTires(radius)
  local frictionCoef = 1.7 -- slick tires
  local downforce = 9.8 -- earth gravity
  local accel = frictionCoef * downforce
  return math.sqrt(accel*radius) -- velocity in m/s
end

local pacenotes = nil
local function initPacenotes(newRoute)
  local route = newRoute

  -- 1st pass:
  local arcs = {}
  local arcPrev = nil
  for k,v in ipairs(route) do
    -- on each point
    if k > 3 then
      local arc = {}

      -- get positions and circle data
      local p1, p2, p3 = route[k-2].pos, route[k-1].pos, route[k].pos
      local p1z, p2z, p3z = p1:z0(), p2:z0(), p3:z0()
      local d1, d2, d1l, d2l, center, angle = circleDist1Dist2CenterAngleFromPoints(p1z, p2z, p3z)
      center.z = p2.z
      arc.center = center
      arc.positions = { p1, p2, p3 }
      arc.midpositions = { 0.5*(p1+p2), p2, 0.5*(p2+p3) }
      arc.deltas = { d1, d2 }
      arc.lengths = { d1l, d2l }
      arc.length = 0.5*(d1l+d2l)

      -- get radius
      local radius = p1:distance(center)
      arc.radius = radius

      -- get velocity of turn
      local vel = getTurnVelocityWithSlickTires(arc.radius)
      arc.vel = vel*3.6 -- in kmh

      -- get time of turn
      arc.time = arc.length / vel

      if arcPrev then
        local dist = arcPrev.lengths[2] + arc.lengths[1]

        -- get velocity accel against previous arc
        local accel = (arcPrev.vel - arc.vel) / dist
        arc.accel = accel

        -- get radius accel against previous arc
        local raccel = (arcPrev.radius - arc.radius) / dist
        arc.raccel = raccel
      end

      -- get severity (based on velocity)
      for severityId,severity in ipairs(severities) do
        if arc.vel < severity.velmax then
          arc.severityId = severityId
          arc.severity = severity
          break
        end
      end

      -- get direction
      local cross = (p3z-p2z):cross(p2z-p1z).z
      arc.direction = arc.severityId == straightId and "" or (cross > 0 and " right" or " left")

      -- get angle
      arc.angle = angle * sign(cross) -- positive is right, negative is left

      -- add pacenote
      table.insert(arcs, arc)
      arcPrev = arc
    end
  end

  -- 2nd pass: merge identical consecutive arcs into a single pacenote
  pacenotes = {}
  local pacenote = {arcs={}, angle=0, length=0, time=0}
  for i,arc in ipairs(arcs) do
    -- detect if this arc is part of the running pacenote, or should be a new one
    local samePacenote = false
    local lastArc = pacenote.arcs[#pacenote.arcs]
    if lastArc then
      local sameDirection = lastArc.direction == arc.direction
      if sameDirection then
        if math.abs(arc.accel) < 4 then samePacenote = true end
      end
      if (arc.severityId == straightId) and (lastArc.severityId == arc.severityId) then samePacenote = true end
    end

    -- write pacenote and start a new one
    if not samePacenote then
      if next(pacenote.arcs) then
        table.insert(pacenotes, pacenote)
        pacenote = {arcs={}, angle=0, length=0, time=0}
      end
    end

    -- add this arc to current pacenote
    table.insert(pacenote.arcs, arc)
    pacenote.angle = pacenote.angle + arc.angle
    pacenote.length = pacenote.length + arc.length
    pacenote.time = pacenote.time + arc.time
  end
  -- write final pacenote
  if next(pacenote.arcs) then
    table.insert(pacenotes, pacenote)
  end

  -- 3rd pass: recompute tightest arcs into square/hairpin/slow
  for i,pacenote in ipairs(pacenotes) do
    local tightestArc = pacenote.arcs[1]
    local velLowest = 1e10
    for i,c in ipairs(pacenote.arcs) do
      if c.vel < velLowest then
        velLowest = c.vel
        tightestArc = c
      end
    end
    pacenote.tightestArc = tightestArc
    pacenote.severityId = tightestArc.severityId
    pacenote.severity = tightestArc.severity
    pacenote.name = pacenote.severity.name
    if tightestArc.severityId == tightestId then
      if math.abs(pacenote.angle) < 60 then
        pacenote.name = pacenote.severity.name3
      elseif math.abs(pacenote.angle) < 120 then
        pacenote.name = pacenote.severity.name2
      end
    elseif tightestArc.severityId == straightId then
      pacenote.name = string.format("%i", math.floor(pacenote.length/10)*10)
    end
  end
end

local rlcolor = ColorF(0,0,0,0)
local tagPos = vec3()

local function renderArc(arc, renderLine, renderText)
  local color = arc.severity.color
  if renderLine then
    debugDrawer:drawSphere(arc.midpositions[1], 0.7, white)
    debugDrawer:drawCylinder(arc.midpositions[1], arc.midpositions[2], 0.15, color)
    debugDrawer:drawCylinder(arc.midpositions[2], arc.midpositions[3], 0.15, color)
  end

  if renderText then
    local c = arc.angle > 0 and darkblue or darkred
    local vel = currentVelocity or arc.vel
    local mul = clamp(arc.vel/(200), 0, 1)
    rlcolor.r, rlcolor.g, rlcolor.b, rlcolor.a = c.r*mul, c.g*mul, c.b*mul, c.a
    --rlcolor = color
    local txt = string.format("%.0fkmh, %.0fm, %.0fdeg, %.1fm/ss", vel, arc.length, arc.angle, arc.accel or 0)
    --local txt = string.format("%.0fkmh, %0.1fs", vel, arc.time)
    tagPos:set(arc.midpositions[1])
    tagPos.z = tagPos.z + 2
    debugDrawer:drawCylinder(arc.midpositions[1], tagPos, 0.05, color)
    debugDrawer:drawSphere(arc.midpositions[1], 0.7, white)
    debugDrawer:drawSphere(arc.midpositions[2], 0.7, color)
    debugDrawer:drawTextAdvanced(tagPos, txt, black, true, false, temporaryColorI(color))
  end
end

local function getPacenoteCall(txt, pacenote, pacenoteNext)
  local linkText = " into"
  if not pacenoteNext then
    linkText = ""
  elseif pacenoteNext.severityId == straightId then
    linkText = " "..pacenoteNext.name
  end
  return  txt..linkText
end
local function getPacenoteText(pacenote)
  local shortThreshold = 0.7 -- in seconds
  local longThreshold = 4.0 -- in seconds
  local tightensThreshold = 1.6 -- in normalized percentage (1.6 means 60% tightening)

  local tightestArc = pacenote.tightestArc
  local firstArc = pacenote.arcs[1]
  local lastArc = pacenote.arcs[#pacenote.arcs]
  local long = tightestArc.severityId ~= straightId and (pacenote.time > longThreshold) or false
  local short = tightestArc.severityId ~= straightId and (pacenote.time < shortThreshold) or false
  local tightens = tightestArc.severityId ~= straightId and (firstArc.vel / lastArc.vel > tightensThreshold) or false
  local opens = tightestArc.severityId ~= straightId and (firstArc.vel / lastArc.vel < 1/tightensThreshold)
  return string.format("%s%s%s%s%s%s" -- %.0fdeg"
    ,pacenote.name
    ,tightestArc.direction
    ,long and " long" or ""
    ,short and " short" or ""
    ,tightens and " tightens" or ""
    ,opens and " opens" or ""
    --,pacenote.angle
  )
end

local pacenoteThickness = 0.35
local pacenoteThickness = 0.15
local function renderPacenote(pacenote, txt)
  local tightestArc = pacenote.tightestArc
  local color = pacenote.severity.color
  for i,arc in ipairs(pacenote.arcs) do
    if i == 1 then
      tagPos:set(arc.midpositions[1])
      tagPos.z = tagPos.z + 2
      debugDrawer:drawCylinder(arc.midpositions[1], tagPos, 0.05, color)
      debugDrawer:drawSphere(arc.midpositions[1], pacenoteThickness*2, white)
      debugDrawer:drawTextAdvanced(tagPos, txt, black, true, false, temporaryColorI(white))
    end
    debugDrawer:drawSphere(arc.midpositions[1], pacenoteThickness * (i==1 and 2 or 0.2), i==1 and color or white)
    debugDrawer:drawCylinder(arc.midpositions[1], arc.midpositions[2], pacenoteThickness, color)
    debugDrawer:drawCylinder(arc.midpositions[2], arc.midpositions[3], pacenoteThickness, color)
  end
end

local minAmountToRender = 2
local function renderNextPacenotes(timeToRender, currentPosition, currentVelocity)
  local predictedTime = 4 -- upcoming distance to show pacenotes for
  local iClosest, jClosest, distClosest = nil, nil, 1e30
  for i,pacenote in ipairs(pacenotes) do
    for j,arc in ipairs(pacenote.arcs) do
      local dist = currentPosition:squaredDistance(arc.midpositions[1])
      if dist < distClosest then
        iClosest, jClosest, distClosest = i, j, dist
      end
    end
  end

  if iClosest then
    local amountRendered = 0
    local timeToRender = predictedTime -- how many seconds worth of pacenotes to show on screen at once
    local nextArc = jClosest
    for i=iClosest, #pacenotes do
      local pacenote = pacenotes[i]
      for j=nextArc or 1, #pacenote.arcs do
        local arc = pacenote.arcs[j]
        local arcVel = math.min(currentVelocity, arc.vel) -- at current or potential reduced speed
        local arcTime = arc.length / arcVel
        timeToRender = timeToRender - arcTime
      end
      nextArc = nil
      local txt = getPacenoteText(pacenote)
      renderPacenote(pacenote, txt)
      amountRendered = amountRendered + 1
      if amountRendered == 2 then
        if pacenote.severityId ~= straightId then
          local pacenoteNext = pacenotes[i+1]
          local txtCall = getPacenoteCall(txt, pacenote, pacenoteNext)
          guihooks.trigger('ScenarioRealtimeDisplay', {msg = txtCall})
        end
      end
      if amountRendered >= minAmountToRender and timeToRender <= 0 then break end
    end
  end
end

local function renderAllPacenotes(showArcs)
  for i,pacenote in ipairs(pacenotes) do
    for j,arc in ipairs(pacenote.arcs) do
      if showArcs then
        local dist = core_camera.getPosition():distance(arc.midpositions[1])
        renderArc(arc, dist < 1000, dist < 100)
      end
    end

    if not showArcs then
      local txt = getPacenoteText(pacenote)
      renderPacenote(pacenote, txt)
    end
  end
end

local vehPos = vec3()
local vehVel = vec3()
local function onUpdate(dt, dtSim)
  if not core_groundMarkers.currentlyHasTarget() then
    pacenotes = nil
    return
  end
  --if dtSim < 0.001 then return end

  if not pacenotes then
    initPacenotes(core_groundMarkers.routePlanner.path)
  end

  local veh = getPlayerVehicle(0)
  local vel = 0
  if veh then
    vehPos:set(veh:getPositionXYZ())
    vehVel:set(veh:getVelocityXYZ())
    vel = vehVel:length()
  end

  if vel < 1 then
    if debug then
      renderAllPacenotes(dtSim < 0.001)
    end
  else
    local timeToRender = 4
    renderNextPacenotes(timeToRender, vehPos, vel)
  end
end

M.onUpdate = onUpdate

return M
