-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local min, max, abs, huge = math.min, math.max, math.abs, math.huge
local tableInsert, tableClear, tableRemove = table.insert, table.clear, table.remove
local stringFormat = string.format

-- these are defined in C, do not change the values
local NORMALTYPE = 0
local BEAM_ANISOTROPIC = 1
local BEAM_BOUNDED = 2
local BEAM_PRESSURED = 3
local BEAM_LBEAM = 4
local BEAM_BROKEN = 5
local BEAM_HYDRO = 6
local BEAM_SUPPORT = 7

local beamTypesNames = {
  [NORMALTYPE] = "NORMALTYPE",
  [BEAM_ANISOTROPIC] = "BEAM_ANISOTROPIC",
  [BEAM_BOUNDED] = "BEAM_BOUNDED",
  [BEAM_PRESSURED] = "BEAM_PRESSURED",
  [BEAM_LBEAM] = "BEAM_LBEAM",
  [BEAM_BROKEN] = "BEAM_BROKEN",
  [BEAM_HYDRO] = "BEAM_HYDRO",
  [BEAM_SUPPORT] = "BEAM_SUPPORT",
}

local beamTypesColors = {
  [NORMALTYPE] = color(0, 223, 0, 255),
  [BEAM_HYDRO] = color(0, 100, 255, 255),
  [BEAM_ANISOTROPIC] = color(255, 135, 63, 255),
  [BEAM_BOUNDED] = color(255, 255, 0, 255),
  [BEAM_LBEAM] = color(92, 92, 92, 255),
  [BEAM_SUPPORT] = color(223, 0, 223, 255),
  [BEAM_PRESSURED] = color(0, 255, 255, 255),
  [BEAM_BROKEN] = color(255, 0, 0, 255),
}

local TRI_NORMAL = 1
local TRI_BACK = 2
local TRI_PRESSURE = 3
local TRI_NONCOLLIDABLE = 4
local TRI_BROKEN = 5

local triTypesNames = {
  'NORMAL',
  'BACK',
  'PRESSURE',
  'NONCOLLIDABLE',
  'BROKEN',
}

local triTypesColors = {
  color(0, 255, 0, 255),
  color(255, 0, 255, 255),
  color(0, 255, 255, 255),
  color(255, 255, 0, 255),
  color(255, 0, 0, 255),
}

local TORBAR_NORMAL = 1
local TORBAR_ANISOTROPIC = 2
local TORBAR_BROKEN = 3

local torbarTypesNames = {
  'NORMAL',
  'ANISOTROPIC',
  'BROKEN',
}

local torbarTypesColors = {
  {color(0,255,0,255), color(0,255,255,255)},
  {color(255,0,255,255), color(0,0,255,255)},
  {color(255,0,0,255), color(255,128,0,255)},
}

local nodeTextMaxDistCap = 10

M.initState = {
  vehicleDebugVisible = false,
  objectId = objectId,
  vehicle = {
    nodeTextMode = 1,
    nodeTextModes = {
      {name = "off"},
      {name = "names"},
      {name = "numbers"},
      {name = "names+numbers"},
      {name = "weights"},
      {name = "materials"},
      {name = "groups"},
      {name = "forces"},
      {name = "relativePositions"},
      {name = "worldPositions"},
      {name = "clusters"},
    },
    nodeTextMaxDistCap = nodeTextMaxDistCap,
    nodeTextMaxDist = nodeTextMaxDistCap,
    nodeTextShowWheels = false,
    nodeVisMode = 1,
    nodeVisModes = {
      {name = "off"},
      {name = "simple"},
      {name = "highlighted"},
      {name = "weights"},
      {name = "displacement"},
      {name = "velocities"},
      {name = "forces", usesRange = true, rangeMinCap = 0, rangeMaxCap = 1000000, rangeMin = 0, rangeMax = 10000, rangeMinEnabled = false, rangeMaxEnabled = false, usesInclusiveRange = true},
      {name = "density"},
      {name = "clusters"},
      {name = "mainCluster"},
      {name = "nodeStability"},
    },
    nodeVisShowHighlighted = false,
    nodeVisWidthScale = 1,
    nodeVisAlpha = 1,
    nodeDebugTextTypeToID = {},
    nodeDebugTextMode = 1,
    nodeDebugTextModes = {
      {name = "off"},
    },
    beamTextShowWheels = true,
    beamTextMode = 1,
    beamTextModes = {
      {name = "off"},
      {name = "ids"},
      {name = "spawnLength"},
      {name = "liveLength"},
    },
    beamVisMode = 1,
    beamVisModes = {
      {name = "off"},
      {name = "simple"},
      {name = "highlighted"},
      {name = "type"},
      {name = "type+broken"},
      {name = "brokenOnly"},
      {name = "supportOnly"},
      {name = "oldStress"},
      {name = "stress", usesRange = true, rangeMinCap = 0, rangeMaxCap = 1000000, rangeMin = 0, rangeMax = 10000, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "displacement", usesRange = true, rangeMinCap = 0.0, rangeMaxCap = 1.0, rangeMin = 0.0, rangeMax = 0.1, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "deformation", usesRange = true, rangeMinCap = 0.0, rangeMaxCap = 1.0, rangeMin = 0.0, rangeMax = 1.0, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "breakgroups"},
      {name = "deformgroups"},
      {name = "boundedBeamBounds"},
      {name = "supportBeamBounds"},
      {name = "frequency", usesSliders = true, sliders = {{name = 'Frequency', val = 100, minVal = 0, maxVal = 1000}, {name = 'Max Amplitude', val = 0.1, minVal = 0, maxVal = 1}}},
      {name = "beamDamp", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamDampFast", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamDampRebound", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamDampReboundFast", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamDampVelocitySplit", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamDeform", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamLimitDamp", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamLimitDampRebound", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamLimitSpring", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamLongBound", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamPrecompression", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamPrecompressionTime", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamShortBound", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamSpring", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "beamStrength", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "boundZone", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "dampCutoffHz", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "dampExpansion", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "deformLimit", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "deformLimitExpansion", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "deformationTriggerRatio", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "longBoundRange", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "precompressionRange", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "shortBoundRange", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "springExpansion", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
    },
    beamVisShowHighlighted = false,
    beamVisWidthScale = 1,
    beamVisAlpha = 1,
    torsionBarVisMode = 1,
    torsionBarVisModes = {
      {name = "off"},
      {name = "simple"},
      {name = "type"},
      {name = "withoutBroken"},
      {name = "withBroken"},
      {name = "brokenOnly"},
      {name = "angle", usesRange = true, rangeMinCap = 0, rangeMaxCap = 360, rangeMin = 0, rangeMax = 20, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "stress", usesRange = true, rangeMinCap = 0, rangeMaxCap = 100000, rangeMin = 0, rangeMax = 10000, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "deformation", usesRange = true, rangeMinCap = 0.0, rangeMaxCap = 10.0, rangeMin = 0.0, rangeMax = 1.0, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "damp", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "deform", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "spring", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
      {name = "strength", usesRange = true, autoRange = true, showInfinity = true, rangeMinEnabled = true, rangeMaxEnabled = true, usesInclusiveRange = true},
    },
    torsionBarVisWidthScale = 1,
    torsionBarVisAlpha = 1,
    railsSlideNodesVisMode = 1,
    railsSlideNodesVisModes = {
      {name = "off"},
      {name = "simple"},
      {name = "withoutBroken"},
      {name = "withBroken"},
      {name = "brokenOnly"},
    },
    railsSlideNodesVisWidthScale = 1,
    railsSlideNodesVisAlpha = 1,
    cogMode = 1,
    cogModes = {
      {name = "off"},
      {name = "on"},
      {name = "nowheels"}
    },
    collisionTriangleVisMode = 1,
    collisionTriangleVisModes = {
      {name = "off"},
      {name = "simple"},
      {name = "type"},
      {name = "withoutBroken"},
      {name = "withBroken"},
      {name = "brokenOnly"},
      {name = "collideableOnly"},
    },
    collisionTriangleVisAlpha = 0.5,
    aeroMode = 1,
    aeroModes = {
      {name = "off"},
      {name = "drag+lift"},
      {name = "aoa"},
      {name = "combined"}
    },
    aerodynamicsScale = 0.1,
    tireContactPoint = false,
    steeringGeometry = false,
    steeringGeometryLineLength = 20,
    wheelThermals = false,
  }
}

M.stateNoReset = {}

M.partsState = {
  partsSelected = {}
}

local nodeDisplayDistance = 0 -- broken atm since it uses the center point of the camera :\
local wheelContacts = {rendered = false, data = {}}

local nodesCount = 0
local beamsCount = 0
local trisCount = 0
local torsionBarsCount = 0
local railsCount = 0
local slidenodesCount = 0

local beamsBroken = {}
local beamsDeformed = {}
local deformGroupsTriggerDisplayed = {}
local brokenBreakGroupsDisplayed = {}

local railsLinksBeams

local clusterIndexToColorIndex = {}

local requestDrawnNodesCallbacks
local requestDrawnBeamsCallbacks

local viewportSizeX = 0
local viewportSizeY = 0
local legendDefaultY = 200
local legendRightOffset = 450
local legendLineH = 20
local legendColW = 325
local legendCol, legendRow = -1, 0

local function resetLegendLayout()
  legendCol, legendRow = -1, 0
end

local function nextLegendColumn()
  legendCol, legendRow = legendCol + 1, 0
end

local function drawLegendText(col, text)
  if not playerInfo.firstPlayerSeated then return end
  obj.debugDrawProxy:drawText2D(vec3(viewportSizeX - legendRightOffset - legendCol * legendColW, legendDefaultY + legendRow * legendLineH, 0), col, text)
  legendRow = legendRow + 1
end

local cellsToCheck = {
  {0, 0, 0},
  {0, 0, 1},
  {0, 0, -1},
  {0, 1, 0},
  {0, -1, 0},
  {1, 0, 0},
  {-1, 0, 0},
  {1, 1, 0},
  {1, -1, 0},
  {-1, 1, 0},
  {-1, -1, 0},
  {0, 1, 1},
  {0, 1, -1},
  {0, -1, 1},
  {0, -1, -1},
  {1, 0, 1},
  {1, 0, -1},
  {-1, 0, 1},
  {-1, 0, -1}
}
local overlapSize = 0.001
local groupIDCount = 1
local groupIDToEntries, hashToGroupID, tblPool = {}, {}, {}
local bigOffset = vec3(1e5, 1e5, 1e5)

local tempVec = vec3()
local tempVec2 = vec3()

local function vecRoundNear(v, m)
  v.x = roundNear(v.x, m)
  v.y = roundNear(v.y, m)
  v.z = roundNear(v.z, m)
end

local function getPosHash(v, offX, offY, offZ)
  local x, y, z = roundNear(v.x, overlapSize), roundNear(v.y, overlapSize), roundNear(v.z, overlapSize)
  local hash = bit.bxor(bit.bxor((x + (offX or 0)) * 73856093, (y + (offY or 0)) * 19349663), (z + (offZ or 0)) * 83492791)
  return not isnaninf(hash) and hash or 0
end

local function nodeCollision(p)
  if not M.state.vehicle.tireContactPoint then
    M.nodeCollision = nop
    return
  end
  local wheelId = v.data.nodes[p.id1].wheelID
  if wheelId then

    if wheelContacts.rendered then
      -- We finished rendering the wheel contacts for the last frame, so we can clear the data
      -- and start rendering the new frame with the new data
      tableClear(wheelContacts.data)
      wheelContacts.rendered = false
    end
    if not wheelContacts.data[wheelId] then
      wheelContacts.data[wheelId] = {totalForce = 0, contactPoint = vec3(0, 0, 0)}
    end
    local wheelC = wheelContacts.data[wheelId]
    wheelC.totalForce = wheelC.totalForce + p.normalForce
    wheelC.contactPoint = wheelC.contactPoint + vec3(p.pos) * p.normalForce
  end
end

local function beamBroke(id, energy)
  local beam = v.data.beams[id]
  log("I", "bdebug.beamBroken", stringFormat("beam %d broke: %s [%d]  ->  %s [%d]", id, (v.data.nodes[beam.id1].name or "unnamed"), beam.id1, (v.data.nodes[beam.id2].name or "unnamed"), beam.id2))
  guihooks.message({txt = "vehicle.beamstate.beamBroke", context = {id = id, id1 = beam.id1, id2 = beam.id2, id1name = v.data.nodes[beam.id1].name, id2name = v.data.nodes[beam.id2].name}})

  beamsBroken[id] = true
end

local function printBeamDeformed(id)
  local beam = v.data.beams[id]
  log("I", "bdebug.beamDeformed", stringFormat("beam %d deformed: %s [%d]  ->  %s [%d]", id, (v.data.nodes[beam.id1].name or "unnamed"), beam.id1, (v.data.nodes[beam.id2].name or "unnamed"), beam.id2))
end

local function printBeamDeformGroupTriggered(deformGroup, beamID)
  local beam = v.data.beams[beamID]
  log("I", "bdebug.beamDeformGroupTriggered", stringFormat("deformgroup triggered: %s beam %d, %s [%d]  ->  %s [%d]", deformGroup, beamID, (v.data.nodes[beam.id1].name or "unnamed"), beam.id1, (v.data.nodes[beam.id2].name or "unnamed"), beam.id2))
end

local function printBreakGroupBroken(g)
  log("I", "bdebug.breakGroupBroken", stringFormat("breakgroup broke: %s", g))
end

local function debugDrawNode(col, node, txt)
  if node.name == nil then
    obj.debugDrawProxy:drawNodeText(node.cid, col, string"[" .. tostring(node.cid) .. "] " .. txt, nodeDisplayDistance)
  else
    obj.debugDrawProxy:drawNodeText(node.cid, col, tostring(node.name) .. " " .. txt, nodeDisplayDistance)
  end
end

local function visualizeWheelThermals()
  if M.state.vehicle.wheelThermals then
    local baseTemp = obj:getEnvTemperature() - 10

    for _, wd in pairs(wheels.wheels) do
      local pressureGroupID = v.data.pressureGroups[wd.pressureGroup]

      if pressureGroupID then
        local wheelAvgTemp = obj:getWheelAvgTemperature(wd.wheelID)
        local wheelCoreTemp = obj:getWheelCoreTemperature(wd.wheelID)

        local wheelAirPressure = obj:getGroupPressure(pressureGroupID)
        obj.debugDrawProxy:drawNodeSphere(wd.node1, 0.04, ironbowColor((wheelCoreTemp - baseTemp) * 0.004))
        obj.debugDrawProxy:drawNodeSphere(wd.node2, 0.04, ironbowColor((wheelCoreTemp - baseTemp) * 0.004))
        obj.debugDrawProxy:drawNodeText(wd.node1, ironbowColor((wheelCoreTemp - baseTemp) * 0.004), stringFormat("%s%.1f %s%.1f %s%.1f", "tT:", wheelAvgTemp - 273.15, "tC:", wheelCoreTemp - 273.15, "psi:", wheelAirPressure*0.000145038-14.5), 0)

        --local wheelAvgTemp = obj:getwheelCoreTemperature(wd.wheelID)

        for _, nid in pairs(wd.treadNodes or {}) do
          obj.debugDrawProxy:drawNodeSphere(nid, 0.02, ironbowColor((obj:getNodeTemperature(nid) - baseTemp) * 0.004))
        end
        for _, nid in pairs(wd.nodes or {}) do
          obj.debugDrawProxy:drawNodeSphere(nid, 0.02, ironbowColor((obj:getNodeTemperature(nid) - baseTemp) * 0.004))
        end
      end
    end
  end
end

local function visualizeTireContactPoint()
  if M.state.vehicle.tireContactPoint then
    M.nodeCollision = nodeCollision
    for _, c in pairs(wheelContacts.data) do
      obj.debugDrawProxy:drawSphere(0.02, (c.contactPoint / c.totalForce), color(255, 0, 0, 255))
    end
    wheelContacts.rendered = true
  end
end

local function visualizeSteeringGeometry()
  if M.state.vehicle.steeringGeometry then
    if v.data.wheels then
      local lineLen = M.state.vehicle.steeringGeometryLineLength
      for i = 0, tableSizeC(v.data.wheels) - 1 do
        local w = v.data.wheels[i]
        local node1, node2 = w.node1, w.node2
        if node1 and node2 then
          local node1Pos, node2Pos = obj:getAbsNodePosition(node1), obj:getAbsNodePosition(node2)
          local midPos = (node1Pos + node2Pos) * 0.5
          local dir = (node2Pos - node1Pos):normalized()

          -- drawing same line twice with both depth testing enabled and disabled to show where the line intersects with the ground
          -- TODO: temporary solution to draw from GE Lua side
          obj:queueGameEngineLua(stringFormatWorkBuffer('debugDrawer:drawLine(%s,%s,ColorF(1,0,0,1),false)', -dir * lineLen * 0.5 + midPos, dir * lineLen * 0.5 + midPos))
          obj.debugDrawProxy:drawCylinder(-dir * lineLen * 0.5 + midPos, dir * lineLen * 0.5 + midPos, 0.01, color(255, 0, 0, 255))
        end
      end
    end
  end
end

local function visualizeCollisionTriangles()
  local partsSelected = M.partsState.partsSelected

  local modeID = M.state.vehicle.collisionTriangleVisMode
  local mode = M.state.vehicle.collisionTriangleVisModes[modeID]
  if not mode then return false end

  local modeName = mode.name

  local alpha = M.state.vehicle.collisionTriangleVisAlpha * 255

  -- "off"
  if modeID == 1 then return end

  if playerInfo.firstPlayerSeated then
    nextLegendColumn()
    drawLegendText(color(255, 165, 0, 255), "Triangle Vis Mode: " .. modeName)
  end

  local outlineColor = color(0, 0, 0, alpha)
  local r,g,b,_ = colorGetRGBA(triTypesColors[TRI_NORMAL])
  local frontColNormal = color(r, g, b, alpha)
  r,g,b,_ = colorGetRGBA(triTypesColors[TRI_BACK])
  local backColBack = color(r, g, b, alpha)
  r,g,b,_ = colorGetRGBA(triTypesColors[TRI_PRESSURE])
  local frontColPress = color(r, g, b, alpha)
  r,g,b,_ = colorGetRGBA(triTypesColors[TRI_NONCOLLIDABLE])
  local frontColNonCol = color(r, g, b, alpha)
  r,g,b,_ = colorGetRGBA(triTypesColors[TRI_BROKEN])
  local frontColBroken = color(r, g, b, alpha)

  -- "simple"
  if modeID == 2 then
    local frontCol = frontColNormal
    local backCol = backColBack

    for i = 0, trisCount - 1 do
      local tri = v.data.triangles[i]

      if partsSelected[tri.partPath or v.config.partsTree.partPath] then
        -- Front
        obj.debugDrawProxy:drawNodeTriangle(tri.id1, tri.id2, tri.id3, 0, frontCol)
        -- Back
        obj.debugDrawProxy:drawNodeTriangle(tri.id1, tri.id2, tri.id3, -0.001, backCol)

        obj.debugDrawProxy:drawNodeLine(tri.id1, tri.id2, outlineColor)
        obj.debugDrawProxy:drawNodeLine(tri.id2, tri.id3, outlineColor)

        if tri.beamCount == 3 then
          obj.debugDrawProxy:drawNodeLine(tri.id3, tri.id1, outlineColor)
        end
      end
    end

  -- "type"
  elseif modeID == 3 then
    for i = 0, trisCount - 1 do
      local tri = v.data.triangles[i]

      if partsSelected[tri.partPath or v.config.partsTree.partPath] then
        local frontCol = frontColNormal
        local backCol = backColBack
        if tri.pressure then
          frontCol = frontColPress
        elseif tri.triangleType == 2 then
          frontCol = frontColNonCol
        end

        -- Front
        obj.debugDrawProxy:drawNodeTriangle(tri.id1, tri.id2, tri.id3, 0, frontCol)
        -- Back
        obj.debugDrawProxy:drawNodeTriangle(tri.id1, tri.id2, tri.id3, -0.001, backCol)

        obj.debugDrawProxy:drawNodeLine(tri.id1, tri.id2, outlineColor)
        obj.debugDrawProxy:drawNodeLine(tri.id2, tri.id3, outlineColor)

        if tri.beamCount == 3 then
          obj.debugDrawProxy:drawNodeLine(tri.id3, tri.id1, outlineColor)
        end
      end
    end

    -- Color legend
    if playerInfo.firstPlayerSeated then
      for i = 1, #triTypesNames do
        if i ~= TRI_BROKEN then
          drawLegendText(triTypesColors[i], triTypesNames[i])
        end
      end
    end

  -- "withoutBroken", "withBroken", "brokenOnly"
  elseif modeID == 4 or modeID == 5 or modeID == 6 then
    for i = 0, trisCount - 1 do
      local tri = v.data.triangles[i]

      if partsSelected[tri.partPath or v.config.partsTree.partPath] then
        local triBroken = obj:isTriangleBroken(i)

        if (modeID == 4 and not triBroken) or modeID == 5 or (modeID == 6 and triBroken) then
          local frontCol = frontColNormal
          local backCol = backColBack
          if triBroken then
            frontCol = frontColBroken
            backCol = frontColBroken
          elseif tri.pressure then
            frontCol = frontColPress
          elseif tri.triangleType == 2 then
            frontCol = frontColNonCol
          end

          -- Front
          obj.debugDrawProxy:drawNodeTriangle(tri.id1, tri.id2, tri.id3, 0, frontCol)
          -- Back
          obj.debugDrawProxy:drawNodeTriangle(tri.id1, tri.id2, tri.id3, -0.001, backCol)

          obj.debugDrawProxy:drawNodeLine(tri.id1, tri.id2, outlineColor)
          obj.debugDrawProxy:drawNodeLine(tri.id2, tri.id3, outlineColor)

          if tri.beamCount == 3 then
            obj.debugDrawProxy:drawNodeLine(tri.id3, tri.id1, outlineColor)
          end
        end
      end
    end

    -- Color legend
    if playerInfo.firstPlayerSeated then
      for i = 1, #triTypesNames do
        drawLegendText(triTypesColors[i], triTypesNames[i])
      end
    end

  -- "collideableOnly"
  elseif modeID == 7 then
    for i = 0, trisCount - 1 do
      local tri = v.data.triangles[i]

      if partsSelected[tri.partPath or v.config.partsTree.partPath] then
        if tri.triangleType ~= 2 and not obj:isTriangleBroken(i) then
          local frontCol = frontColNormal
          local backCol = backColBack
          if tri.pressure then
            frontCol = frontColPress
          end

          -- Front
          obj.debugDrawProxy:drawNodeTriangle(tri.id1, tri.id2, tri.id3, 0, frontCol)
          -- Back
          obj.debugDrawProxy:drawNodeTriangle(tri.id1, tri.id2, tri.id3, -0.001, backCol)

          obj.debugDrawProxy:drawNodeLine(tri.id1, tri.id2, outlineColor)
          obj.debugDrawProxy:drawNodeLine(tri.id2, tri.id3, outlineColor)

          if tri.beamCount == 3 then
            obj.debugDrawProxy:drawNodeLine(tri.id3, tri.id1, outlineColor)
          end
        end
      end
    end

    -- Color legend
    if playerInfo.firstPlayerSeated then
      for i = 1, #triTypesNames do
        if i ~= TRI_BROKEN and i ~= TRI_NONCOLLIDABLE then
          drawLegendText(triTypesColors[i], triTypesNames[i])
        end
      end
    end
  end
end

local function visualizeAerodynamics()
  local modeID = M.state.vehicle.aeroMode

  -- "off"
  if modeID == 1 then return end

  -- "drag+lift"
  if modeID == 2 then
    obj.debugDrawProxy:drawAerodynamicsCenterOfPressure(color(255, 0, 0, 255), color(55, 55, 255, 255), color(255, 255, 0, 255), color(0, 0, 0, 0), color(0, 0, 0, 0), M.state.vehicle.aerodynamicsScale)

    -- "aoa"
  elseif modeID == 3 then
    obj.debugDrawProxy:drawAerodynamicsCenterOfPressure(color(255, 0, 0, 0), color(55, 55, 255, 0), color(255, 255, 0, 0), color(0, 0, 0, 255), color(0, 0, 0, 0), M.state.vehicle.aerodynamicsScale)

  -- "combined"
  elseif modeID == 4 then
    obj.debugDrawProxy:drawAerodynamicsCenterOfPressure(color(255, 0, 0, 255), color(55, 55, 255, 255), color(255, 255, 0, 255), color(0, 0, 0, 255), color(0, 0, 0, 0), M.state.vehicle.aerodynamicsScale)
  end
end

local function visualizeCOG()
  local modeID = M.state.vehicle.cogMode

  -- "off"
  if not modeID or modeID == 1 then return end

  -- not "off"
  if modeID > 1 then
    local p = obj:calcCenterOfGravity(modeID == 3)
    local vehPos = obj:getPosition()
    local initRefNodePos = v.data.nodes[v.data.refNodes[0].ref].pos
    local rot = quatFromDir(-obj:getDirectionVector(), obj:getDirectionVectorUp())
    local relCOGPos = rot:inversed() * (p - vehPos) + initRefNodePos

    obj.debugDrawProxy:drawAerodynamicsCenterOfPressure(color(0, 0, 0, 0), color(0, 0, 0, 0), color(0, 0, 0, 0), color(0, 0, 0, 0), color(0, 0, 255, 255), 0.1)
    obj.debugDrawProxy:drawSphere(0.1, p, color(255, 0, 0, 255))
    obj.debugDrawProxy:drawText(p + vec3(0, 0, 0.3), color(255, 0, 0, 255), stringFormat("COG (%0.3f, %0.3f, %0.3f)", relCOGPos.x, relCOGPos.y, relCOGPos.z))

    if playerInfo.firstPlayerSeated then
      nextLegendColumn()
      drawLegendText(color(0, 0, 0, 255), "COG distance above ground: " .. stringFormat("%0.3f m", obj:getDistanceFromTerrainPoint(p)))
    end
  end
end

local function visualizeNodesDebugTexts()
  local modeID = M.state.vehicle.nodeDebugTextMode
  if modeID == 1 then return end

  if M.state.vehicle.nodeDebugTextModes[modeID] then
    local nodeColor = color(255,128,0,255)

    for nodeCID, data in pairs(M.state.vehicle.nodeDebugTextModes[modeID].data) do
      local nodePos = obj:getAbsNodePosition(nodeCID)
      for i = #data.textList, 1, -1 do
        local text = data.textList[i]
        obj:queueGameEngineLua(stringFormatWorkBuffer('debugDrawer:drawTextAdvanced(%s,"%s",ColorF(1,1,1,1),true,false,ColorI(0,0,0,192))', tostring(nodePos), text))
      end

      obj.debugDrawProxy:drawNodeSphere(nodeCID, 0.02, nodeColor)
    end
  end
end

local nodePositions = {}
local lastNodeMinDistFromCam, nodeMinDistFromCam = math.huge, math.huge
local camPos = vec3()
local textNodeForceAvg = 1
local textNodeWeightAvg = 1

-- Uses tempVec
local function initRenderNodeTexts()
  camPos = obj:getCameraPosition()
  nodeMinDistFromCam = math.huge
end

local function getNodeText(node, txt)
  return node.name == nil and "[" .. tostring(node.cid) .. "]" .. (txt and ' ' .. txt or '') or tostring(node.name) .. (txt and ' ' .. txt or '')
end

local function postRenderNodeTexts()
  lastNodeMinDistFromCam = nodeMinDistFromCam
end

local function renderNodeText(i, col, txt)
  local pos = obj:getAbsNodePosition(i)
  local dist = pos:distance(camPos)
  nodeMinDistFromCam = math.min(dist, nodeMinDistFromCam)
  local r,g,b,a = colorGetRGBA(col)
  local nodeTextMaxDist = M.state.vehicle.nodeTextMaxDist
  local distToAlpha = nodeTextMaxDist < nodeTextMaxDistCap and (-1 / nodeTextMaxDist * (dist - lastNodeMinDistFromCam) + 1) or nodeTextMaxDistCap
  obj.debugDrawProxy:drawNodeText(i, color(r,g,b, a * distToAlpha), txt, nodeDisplayDistance)
end

local function visualizeNodesTexts()
  local partsSelected = M.partsState.partsSelected

  local modeID = M.state.vehicle.nodeTextMode
  local mode = M.state.vehicle.nodeTextModes[modeID]
  local modeName = mode and mode.name or ""
  local showWheels = M.state.vehicle.nodeTextShowWheels

  -- "off"
  if modeID == 1 then return end

  if playerInfo.firstPlayerSeated then
    nextLegendColumn()
    drawLegendText(color(255, 165, 0, 255), "Node Text Vis Mode: " .. modeName)
  end

  -- "names"
  if modeID == 2 then
    initRenderNodeTexts()
    local col = color(255, 0, 255, 255)
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] and (showWheels or not node.wheelID) then
        local nodeText = getNodeText(node, nil)
        renderNodeText(i, col, nodeText)
      end
    end
    postRenderNodeTexts()

  -- "numbers
  elseif modeID == 3 then
    initRenderNodeTexts()
    local col = color(0, 128, 255, 255)
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] and (showWheels or not node.wheelID) then
        local nodeText = tostring(node.cid)
        renderNodeText(i, col, nodeText)
      end
    end
    postRenderNodeTexts()

  -- "names+numbers"
  elseif modeID == 4 then
    initRenderNodeTexts()
    local col = color(128, 0, 255, 255)
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] and (showWheels or not node.wheelID) then
        local nodeText = getNodeText(node, "" .. node.cid)
        renderNodeText(i, col, nodeText)
      end
    end
    postRenderNodeTexts()

  -- "weights"
  elseif modeID == 5 then
    initRenderNodeTexts()
    local currNodesCount = 0
    local totalWeight = 0
    local newTotalWeight = 0

    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] and (showWheels or not node.wheelID) then
        local nodeWeight = obj:getNodeMass(node.cid)
        local nodeText = getNodeText(node, stringFormat("%.2fkg", nodeWeight))
        local col = color(255 * (nodeWeight / textNodeWeightAvg), 0, 0, 255)
        renderNodeText(i, col, nodeText)

        totalWeight = totalWeight + nodeWeight
        newTotalWeight = newTotalWeight + nodeWeight
        currNodesCount = currNodesCount + 1
      end
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(0, 0, 0, 255), "Total Weight: " .. stringFormat("%.2f kg", totalWeight))
    end
    textNodeWeightAvg = newTotalWeight / (currNodesCount + 1e-30)
    postRenderNodeTexts()

  -- "materials"
  elseif modeID == 6 then
    -- Averaging colors https://stackoverflow.com/a/29576746
    initRenderNodeTexts()
    local materials = particles.getMaterialsParticlesTable()

    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] and (showWheels or not node.wheelID) then
        local mat = materials[node.nodeMaterial]
        local matname = "unknown"
        local col = color(255, 0, 0, 255) -- unknown material: red
        if mat ~= nil then
          col = color(mat.colorR, mat.colorG, mat.colorB, 255)
          matname = mat.name
        end
        local nodeText = getNodeText(node, matname)
        renderNodeText(i, col, nodeText)
      end
    end
    postRenderNodeTexts()

  -- "groups"
  elseif modeID == 7 then
    initRenderNodeTexts()
    local col = color(255, 128, 0, 255)

    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] and (showWheels or not node.wheelID) then
        local txt = nil
        if type(node.group) == "table" then
          txt = '{'
          local ngSize = tableSize(node.group)
          local k = 1
          for _,v in pairs(node.group) do
            txt = txt .. v
            if k ~= ngSize then
              txt = txt .. ', '
            end
            k = k + 1
          end
          txt = txt .. '}'
        else
          txt = stringFormat('{%s}', tostring(node.group or ''))
        end
        local nodeText = getNodeText(node, txt)
        renderNodeText(i, col, nodeText)
      end
    end
    postRenderNodeTexts()

  -- "forces"
  elseif modeID == 8 then
    initRenderNodeTexts()
    local forcesSum = 0
    local invAvgNodeForce = 1 / textNodeForceAvg
    local currNodesCount = 0

    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] and (showWheels or not node.wheelID) then
        local frc = obj:getNodeForceVector(node.cid)
        local frc_length = frc:length()
        forcesSum = forcesSum + frc_length

        local nodeText = getNodeText(node, stringFormat("%0.1f N", frc_length))

        local c = min(255, (frc_length * invAvgNodeForce * 0.5) * 255)
        local col = color(c, 0, 0, (c + 100))
        renderNodeText(i, col, nodeText)
        currNodesCount = currNodesCount + 1
      end
    end

    drawLegendText(color(0, 0, 0, 255), "Average Force: " .. stringFormat("%0.1f N", textNodeForceAvg))
    textNodeForceAvg = forcesSum / (currNodesCount + 1e-30)
    postRenderNodeTexts()

  -- "relativePositions"
  elseif modeID == 9 then
    initRenderNodeTexts()
    local col = color(0, 255, 0, 255)
    local initRefNodePos = v.data.nodes[v.data.refNodes[0].ref].pos

    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] and (showWheels or not node.wheelID) then
        tempVec2:set(obj:getNodePositionRelativeXYZ(node.cid))
        tempVec2:setAdd(initRefNodePos)
        local nodeText = getNodeText(node, stringFormat("(%0.3f, %0.3f, %0.3f)", tempVec2.x, tempVec2.y, tempVec2.z))
        renderNodeText(i, col, nodeText)
      end
    end
    postRenderNodeTexts()

  -- "worldPositions"
  elseif modeID == 10 then
    initRenderNodeTexts()
    local col = color(0, 255, 192, 255)
    tempVec:set(obj:getPositionXYZ())
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] and (showWheels or not node.wheelID) then
        tempVec2:setAdd2(tempVec, obj:getNodePosition(node.cid))
        local nodeText = getNodeText(node, stringFormat("(%0.3f, %0.3f, %0.3f)", tempVec2.x, tempVec2.y, tempVec2.z))
        renderNodeText(i, col, nodeText)
      end
    end
    postRenderNodeTexts()

    -- "clusters"
  elseif modeID == 11 then
    initRenderNodeTexts()
    local numberOfClusters = 0
    tableClear(clusterIndexToColorIndex)
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      local clusterId = obj:getNodeCluster(node.cid)
      if not clusterIndexToColorIndex[clusterId] then
        clusterIndexToColorIndex[clusterId] = numberOfClusters + 1
        numberOfClusters = numberOfClusters + 1
      end
    end

    if numberOfClusters > 0 then
      for i = 0, nodesCount - 1 do
        local node = v.data.nodes[i]
        local clusterId = obj:getNodeCluster(node.cid)
        local col = jetColor(clusterIndexToColorIndex[clusterId] / numberOfClusters)
        renderNodeText(i, col, tostring(clusterId))
      end
    end
    postRenderNodeTexts()
  end
end

-- Exponential moving average of ||F||/m per node for "Node Stability" node vis mode .
local nodeStabilityEma = nil
local nodeStabilityEmaPrevMode = nil
local nodeStabilityThreshold = 315 -- Minimum value to be considered unstable
-- Time constant (seconds) for smoothing the EMA (alpha = 1 - exp(-dt/tau))
local nodeStabilityEmaTau = 0.12
-- Reused for nodeStability: avoid allocating a vec3 per node from getNodeForceVector.
local nodeStabilityForceScratch = vec3()

local visNodeForceAvg = 1
local nodesDrawn
local function visualizeNodes()
  local dirty = false

  local partsSelected = M.partsState.partsSelected
  -- Clearing EMA values when not in "nodeStability" mode
  local modeID = M.state.vehicle.nodeVisMode
  if modeID == 11 then
    if nodeStabilityEmaPrevMode ~= 11 then
      nodeStabilityEma = nodeStabilityEma or {}
      tableClear(nodeStabilityEma)
    end
  elseif nodeStabilityEmaPrevMode == 11 then
    if nodeStabilityEma then
      tableClear(nodeStabilityEma)
    end
  end
  nodeStabilityEmaPrevMode = modeID

  local mode = M.state.vehicle.nodeVisModes[modeID]
  if not mode then return false end

  local rangeMin = mode.rangeMin or -huge
  local rangeMax = mode.rangeMax or huge

  local minVal = huge
  local maxVal = -huge
  local nodeScale = 0.025 * M.state.vehicle.nodeVisWidthScale
  local alpha = M.state.vehicle.nodeVisAlpha

  nodesDrawn = nodesDrawn or {}
  tableClear(nodesDrawn)
  local ndi = 1

  -- "off"
  if modeID == 1 then return dirty end

  -- highlighted nodes
  if M.state.vehicle.nodeVisShowHighlighted or modeID == 3 then
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if node.highlight then
        local col = parseColor(node.highlight.col or node.highlight.color)
        local r,g,b,a = colorGetRGBA(col)
        col = color(r,g,b,a * alpha)
        local radius = (node.highlight.radius or 0.025) * M.state.vehicle.nodeVisWidthScale
        obj.debugDrawProxy:drawNodeSphere(node.cid, radius, col)
      end
    end
  end

  -- "simple"
  if modeID == 2 then
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] then
        local c
        if node.fixed then
          c = color(255, 0, 255, 200 * alpha)
        elseif node.selfCollision then
          c = color(255, 255, 0, 200 * alpha)
        elseif node.collision == false then
          c = color(255, 0, 212, 200 * alpha)
        else
          c = color(0, 255, 255, 200 * alpha)
        end
        obj.debugDrawProxy:drawNodeSphere(node.cid, nodeScale, c)

        nodesDrawn[ndi] = node.cid
        ndi = ndi + 1
      end
    end

  -- mode 3 is highlighted nodes

  -- "weights"
  elseif modeID == 4 then
    local totalWeight, _, _ = extensions.vehicleEditor_nodes.calculateNodesWeight()

    local avgNodeScale = 0

    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] then
        local c
        if node.fixed then
          c = color(255, 0, 255, 200 * alpha)
        elseif node.selfCollision then
          c = color(255, 255, 0, 200 * alpha)
        elseif node.collision == false then
          c = color(255, 0, 212, 200 * alpha)
        else
          c = color(0, 255, 255, 200 * alpha)
        end

        local nodeMass = obj:getNodeMass(node.cid)

        local r = (obj:getNodeMass(node.cid) / (totalWeight / nodesCount)) ^ 0.4 * 0.05
        if nodeMass >= rangeMin and nodeMass <= rangeMax then
          local newNodeScale = r * nodeScale * 50
          obj.debugDrawProxy:drawNodeSphere(node.cid, newNodeScale, c)
          avgNodeScale = avgNodeScale + newNodeScale

          nodesDrawn[ndi] = node.cid
          ndi = ndi + 1
        end
      end
    end

    nodeScale = ndi >= 2 and avgNodeScale / (ndi - 1) or nodeScale

  -- "displacement"
  elseif modeID == 5 then
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] then
        local displacementVec = obj:getNodePositionRelative(node.cid)
        displacementVec:setSub(obj:getOriginalNodePositionRelative(node.cid))
        local displacement = displacementVec:length() * 10

        local a = min(1, displacement) * 255 * alpha
        if a > 5 then
          local r = min(1, displacement) * 255
          obj.debugDrawProxy:drawNodeSphere(node.cid, nodeScale, color(r, 0, 0, a))

          nodesDrawn[ndi] = node.cid
          ndi = ndi + 1
        end
      end
    end

  -- "velocities"
  elseif modeID == 6 then
    local vecVel = obj:getVelocity()
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] then
        local vel = obj:getNodeVelocityVector(node.cid) - vecVel
        local speed = vel:length()

        if speed >= rangeMin and speed <= rangeMax then
          local c = min(255, speed * 10)
          local col = color(c, 0, 0, (c + 60) * alpha)

          obj.debugDrawProxy:drawNodeSphere(node.cid, nodeScale, col)
          obj.debugDrawProxy:drawNodeVector(node.cid, (vel * 0.3), col)

          nodesDrawn[ndi] = node.cid
          ndi = ndi + 1
        end
      end
    end

  -- "forces"
  elseif modeID == 7 then
    local forcesSum = 0
    local invAvgNodeForce = 1 / (visNodeForceAvg * 10 + 300)
    local currNodesCount = 0

    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      local frc = obj:getNodeForceVector(node.cid)
      local frc_length = frc:length()
      if partsSelected[node.partPath or v.config.partsTree.partPath] then
        local withinRange = false
        if mode.rangeMinEnabled and mode.rangeMaxEnabled then
          if mode.usesInclusiveRange and frc_length >= rangeMin and frc_length <= rangeMax
          or not mode.usesInclusiveRange and frc_length > rangeMin and frc_length < rangeMax then
            withinRange = true
          end
        elseif not mode.rangeMinEnabled and not mode.rangeMaxEnabled
        or mode.rangeMinEnabled and (mode.usesInclusiveRange and frc_length >= rangeMin or not mode.usesInclusiveRange and frc_length > rangeMin)
        or mode.rangeMaxEnabled and (mode.usesInclusiveRange and frc_length <= rangeMax or not mode.usesInclusiveRange and frc_length < rangeMax) then
          withinRange = true
        end

        if withinRange then
          forcesSum = forcesSum + frc_length
          local c = min(255, (frc_length * invAvgNodeForce) * 255)
          local col = color(c, 0, 0, (c + 100) * alpha)
          obj.debugDrawProxy:drawNodeSphere(node.cid, nodeScale, col)
          obj.debugDrawProxy:drawNodeVector3d(nodeScale, node.cid, (frc * invAvgNodeForce), col)

          nodesDrawn[ndi] = node.cid
          ndi = ndi + 1
          currNodesCount = currNodesCount + 1
        end
      end
    end
    visNodeForceAvg = forcesSum / (currNodesCount + 1e-30)

  -- "density"
  elseif modeID == 8 then
    local col
    local colorWater = color(255, 0, 0, 200 * alpha)
    local colorAir = color(0, 200, 0, 200 * alpha)
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      if partsSelected[node.partPath or v.config.partsTree.partPath] then
        local inWater = obj:inWater(node.cid)
        if inWater then
          col = colorWater
        else
          col = colorAir
        end
        obj.debugDrawProxy:drawNodeSphere(node.cid, nodeScale, col)

        nodesDrawn[ndi] = node.cid
        ndi = ndi + 1
      end
    end

  -- "clusters"
  elseif modeID == 9 then
    local numberOfClusters = 0
    tableClear(clusterIndexToColorIndex)
    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      local clusterId = obj:getNodeCluster(node.cid)
      if not clusterIndexToColorIndex[clusterId] then
        clusterIndexToColorIndex[clusterId] = numberOfClusters + 1
        numberOfClusters = numberOfClusters + 1
      end
    end

    if numberOfClusters > 0 then
      for i = 0, nodesCount - 1 do
        local node = v.data.nodes[i]
        local clusterId = obj:getNodeCluster(node.cid)
        local col = jetColor(clusterIndexToColorIndex[clusterId] / numberOfClusters)
        obj.debugDrawProxy:drawNodeSphere(node.cid, nodeScale, col)
      end
    end

  -- "mainCluster"
  elseif modeID == 10 then
    local refClusterId = obj:getNodeCluster(v.data.refNodes[0].ref)

    for i = 0, nodesCount - 1 do
      local node = v.data.nodes[i]
      local clusterId = obj:getNodeCluster(node.cid)
      local col = jetColor(refClusterId == clusterId and 0.5 or 0)
      obj.debugDrawProxy:drawNodeSphere(node.cid, nodeScale, col)
    end

  -- "nodeStability"
  elseif modeID == 11 then
    local stabilityEma = nodeStabilityEma
    local dt = lastDt or (1 / 60)
    local emaAlpha = 1 - math.exp(-dt / nodeStabilityEmaTau)
    local invLog1000 = (1000 + 1.8) / (1.3 * 999) -- Approximation of 1 / math.log(1000)
    local maxStabilityValue, maxStabilityNodeIndex = -1e30, 0

    for nodeIndex = 0, nodesCount - 1 do
      local nodeMass = obj:getNodeMass(nodeIndex) or 0
      nodeStabilityForceScratch:set(obj:getNodeForceVectorXYZ(nodeIndex))
      local currentForcePerMass = nodeStabilityForceScratch:length() / (nodeMass + 1e-9)
      local prevStability = stabilityEma[nodeIndex] or currentForcePerMass
      local emaStability = prevStability + emaAlpha * (currentForcePerMass - prevStability)
      stabilityEma[nodeIndex] = emaStability

      if emaStability > maxStabilityValue then
        maxStabilityValue, maxStabilityNodeIndex = emaStability, nodeIndex
      end
    end

    local alphaStable = math.floor(205 * alpha)
    local colorStable = color(70, 130, 255, alphaStable)
    local alphaGreen = math.floor(215 * alpha)
    local colorGreen = color(0, 210, 65, alphaGreen)
    local alphaHigh = math.floor(225 * alpha)
    local colorHigh = color(255, 40, 35, alphaHigh)
    local colorMax = color(255, 255, 255, math.floor(252 * alpha))


    local alphaTransient = min(220, max(0, math.floor(220 * alpha + 0.5)))
    for nodeIndex = 0, nodesCount - 1 do
      if nodeIndex ~= maxStabilityNodeIndex then
        local emaStability = stabilityEma[nodeIndex] or 0
        local sphereRadius, sphereColor

        if emaStability < nodeStabilityThreshold then
          sphereRadius = 0.012
          sphereColor = colorGreen
        elseif emaStability < 1000 then
          -- Lerp depending on the stability value
          local interp = (emaStability - nodeStabilityThreshold) / 700
          interp = min(1, max(0, interp))
          sphereRadius = 0.012 + (0.1 - 0.012) * interp
          sphereColor = jetColor(interp, alphaTransient)
        else
          -- LOG interpolation to emphasize the differences
          local x = emaStability * 0.001
          local interp = ((1.3 * (x - 1)) / (x + 1.8)) * invLog1000 -- Approximation : log(x) ~ (a * (x-1)) / (x + b) with a=1.3, b=1.8
          interp = min(1, max(0, interp))
          sphereRadius = 0.1 + (0.2 - 0.1) * interp
          sphereColor = colorHigh
        end
        obj.debugDrawProxy:drawNodeSphere(v.data.nodes[nodeIndex].cid, sphereRadius, sphereColor)
      end
    end
    if maxStabilityNodeIndex ~= nil and maxStabilityValue >= nodeStabilityThreshold then
      obj.debugDrawProxy:drawNodeSphere(v.data.nodes[maxStabilityNodeIndex].cid, 0.25, colorMax)
    end
  end
  -- If auto range enabled and at least one beam value exists, use it to calculate range min/max values
  if mode.autoRange and minVal ~= huge and maxVal ~= -huge then
    if not mode.rangeMinCap or (mode.rangeMinCap and minVal < mode.rangeMinCap) then
      mode.rangeMinCap = minVal
      dirty = true
    end

    if not mode.rangeMaxCap or (mode.rangeMaxCap and maxVal > mode.rangeMaxCap) then
      mode.rangeMaxCap = maxVal

      if mode.rangeMinCap == mode.rangeMaxCap then
        local magnitude = math.floor(math.log10(abs(mode.rangeMaxCap)))

        mode.rangeMaxCap = mode.rangeMaxCap + math.pow(10, magnitude - 1)
      end

      dirty = true
    end

    if not mode.rangeMin then
      mode.rangeMin = mode.rangeMinCap
      dirty = true
    end

    if not mode.rangeMax then
      mode.rangeMax = mode.rangeMaxCap
      dirty = true
    end
  end

  if requestDrawnNodesCallbacks and next(requestDrawnNodesCallbacks) ~= nil then
    for _, geFuncName in ipairs(requestDrawnNodesCallbacks) do
      obj:queueGameEngineLua(stringFormatWorkBuffer("%s(%s,%f)", geFuncName, serializeWorkBuffer(nodesDrawn), nodeScale))
    end
    tableClear(requestDrawnNodesCallbacks)
  end

  return dirty
end

local beamPositions = {}

local function initRenderBeamTexts(partsSelected, showWheels)
  tableClear(groupIDToEntries)
  tableClear(hashToGroupID)

  groupIDCount = 1

  local vehPos = obj:getPosition()

  for i = 0, nodesCount - 1 do
    nodePositions[i] = obj:getAbsNodePosition(i)
  end

  for i = 0, beamsCount - 1 do
    local beam = v.data.beams[i]
    if partsSelected[beam.partPath or v.config.partsTree.partPath] and (showWheels or not beam.wheelID) then
      tempVec:setAdd2(nodePositions[beam.id1], nodePositions[beam.id2])
      tempVec:setScaled(0.5)
      if not beamPositions[i] then
        beamPositions[i] = vec3()
      end
      beamPositions[i]:set(tempVec)
      tempVec:setSub(vehPos)
      tempVec:setAdd(bigOffset)
      local posHash = getPosHash(tempVec)
      if next(tblPool) == nil then
        tableInsert(tblPool, {})
      end

      local exists = false

      -- check adjacent cells for entries
      for k, v in ipairs(cellsToCheck) do
        local hash = getPosHash(tempVec, v[1] * overlapSize, v[2] * overlapSize, v[3] * overlapSize)
        if hashToGroupID[hash] then
          local groupID = hashToGroupID[hash]
          tableInsert(groupIDToEntries[groupID], i)
          exists = true
          break
        end
      end
      if not exists then
        groupIDCount = groupIDCount + 1
        hashToGroupID[posHash] = groupIDCount
        groupIDToEntries[groupIDCount] = tableRemove(tblPool)
        tableInsert(groupIDToEntries[groupIDCount], i)
      end
    end
  end
end

local function renderBeamText(pos, col, txt, entries)
  obj.debugDrawProxy:drawText(pos, col, txt)
  tableClear(entries)
  tableInsert(tblPool, entries)
end

local function visualizeBeamsTexts()
  local partsSelected = M.partsState.partsSelected

  local modeID = M.state.vehicle.beamTextMode
  local showWheels = M.state.vehicle.beamTextShowWheels

  -- "off"
  if modeID == 1 then return end

  -- "ids"
  if modeID == 2 then
    local col = jetColor(0)
    initRenderBeamTexts(partsSelected, showWheels)
    for groupID, entries in pairs(groupIDToEntries) do
      local text = ''
      local tblSize = #entries
      local pos = beamPositions[entries[1]]
      for k, i in ipairs(entries) do
        local beam = v.data.beams[i]
        local beamText = beam.cid
        text = k ~= tblSize and text .. beamText .. ', ' or text .. beamText
      end
      renderBeamText(pos, col, text, entries)
    end

  -- "spawnLength"
  elseif modeID == 3 then
    local col = jetColor(0.1)
    initRenderBeamTexts(partsSelected, showWheels)
    for groupID, entries in pairs(groupIDToEntries) do
      local text = ''
      local tblSize = #entries
      local pos = beamPositions[entries[1]]
      for k, i in ipairs(entries) do
        local beam = v.data.beams[i]
        local beamText = stringFormat("%d: %.3f m", beam.cid, obj:getBeamRefLength(beam.cid))
        text = k ~= tblSize and text .. beamText .. ', ' or text .. beamText
      end
      renderBeamText(pos, col, text, entries)
    end

  -- "liveLength"
  elseif modeID == 4 then
    local col = jetColor(0.2)
    initRenderBeamTexts(partsSelected, showWheels)
    for groupID, entries in pairs(groupIDToEntries) do
      local text = ''
      local tblSize = #entries
      local pos = beamPositions[entries[1]]
      for k, i in ipairs(entries) do
        local beam = v.data.beams[i]
        local beamText = stringFormat("%d: %.3f m", beam.cid, obj:getBeamLength(beam.cid))
        text = k ~= tblSize and text .. beamText .. ', ' or text .. beamText
      end
      renderBeamText(pos, col, text, entries)
    end
  end
end

local groupsData = {}
local beamsDrawn
local beamFreqModeAmp = {}

local function visualizeBeams()
  local dirty = false

  local partsSelected = M.partsState.partsSelected

  local modeID = M.state.vehicle.beamVisMode
  local mode = M.state.vehicle.beamVisModes[modeID]
  if not mode then return false end

  local modeName = mode.name

  local rangeMin = mode.rangeMin or -huge
  local rangeMax = mode.rangeMax or huge

  local minVal = huge
  local maxVal = -huge

  local beamScale = 0.002 * M.state.vehicle.beamVisWidthScale
  local alpha = M.state.vehicle.beamVisAlpha

  beamsDrawn = beamsDrawn or {}
  tableClear(beamsDrawn)
  local bdi = 1

  -- "off"
  if modeID == 1 then return dirty end

  -- highlighted beams
  if M.state.vehicle.beamVisShowHighlighted or modeID == 3 then
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if beam.highlight then
        local col = parseColor(beam.highlight.col or beam.highlight.color)
        local r,g,b,a = colorGetRGBA(col)
        col = color(r,g,b,a * alpha)

        local len = beam.highlight.len or beam.highlight.length
        local radius = (beam.highlight.radius or 0.01) * M.state.vehicle.beamVisWidthScale

        if len then
          local node1, node2 = beam.id1, beam.id2
          local node1Pos, node2Pos = obj:getAbsNodePosition(node1), obj:getAbsNodePosition(node2)
          local midPos = (node1Pos + node2Pos) * 0.5
          local dir = (node2Pos - node1Pos):normalized()
          -- drawing same line twice with both depth testing enabled and disabled to show where the line intersects with the ground
          -- TODO: temporary solution to draw from GE Lua side
          --obj:queueGameEngineLua(stringFormat('debugDrawer:drawCylinder(%s,%s,%f,ColorF(%f,%f,%f,%f),false)', -dir * len * 0.5 + midPos, dir * len * 0.5 + midPos, radius * 0.5, r/255,g/255,b/255,a/255))
          obj.debugDrawProxy:drawCylinder(-dir * len * 0.5 + midPos, dir * len * 0.5 + midPos, radius, col)
        else
          -- drawing same line twice with both depth testing enabled and disabled to show where the line intersects with the ground
          -- TODO: temporary solution to draw from GE Lua side
          obj.debugDrawProxy:drawBeam3d(beam.cid, radius, col)
          -- obj:queueGameEngineLua(stringFormat('debugDrawer:drawCylinder(%s,%s,%f,ColorF(%f,%f,%f,%f),false)', node1Pos, node2Pos, radius, r/255,g/255,b/255,a/255))
          -- obj.debugDrawProxy:drawCylinder(node1Pos, node2Pos, radius, col)
        end
      end
    end
  end

  if playerInfo.firstPlayerSeated then
    nextLegendColumn()
    drawLegendText(color(255, 165, 0, 255), "Beam Vis Mode: " .. modeName)
  end

  -- "simple"
  if modeID == 2 then
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(0, 223, 0, 255 * alpha))

        beamsDrawn[bdi] = beam.cid
        bdi = bdi + 1
      end
    end

  -- mode 3 is highlighted beams

  -- "type" | "with broken" | "brokenOnly"
  elseif modeID == 4 or modeID == 5 or modeID == 6 then
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        local beamType = beam.beamType or 0

        local col = beamTypesColors[beamType]

        local beamBroken = obj:beamIsBroken(beam.cid)

        if (modeID == 5 or modeID == 6) and beamBroken then
          col = beamTypesColors[BEAM_BROKEN]
        end

        if (modeID == 4 and not beamBroken) or modeID == 5 or (modeID == 6 and beamBroken) then
          local r,g,b,a = colorGetRGBA(col)
          obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, g, b, a * alpha))

          beamsDrawn[bdi] = beam.cid
          bdi = bdi + 1
        end
      end
    end

    -- Color legend
    if playerInfo.firstPlayerSeated and modeID ~= 6 then
      for i = 0, #beamTypesNames do
        drawLegendText(beamTypesColors[i], beamTypesNames[i])
      end
    end

  -- "supportOnly"
  elseif modeID == 7 then
    local col = beamTypesColors[BEAM_SUPPORT]
    local r,g,b,a = colorGetRGBA(col)
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        if beam.beamType == BEAM_SUPPORT and not obj:beamIsBroken(beam.cid) then
          obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, g, b, a * alpha))

          beamsDrawn[bdi] = beam.cid
          bdi = bdi + 1
        end
      end
    end

  -- "stress (old)"
  elseif modeID == 8 then
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        local stress = obj:getBeamStress(beam.cid) * 0.0002
        local a = min(1, abs(stress)) * 255 * alpha
        if a > 5 then
          local r = max(-1, min(0, stress)) * 255 * -1
          local b = max(0, min(1, stress)) * 255
          obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, 0, b, a))

          beamsDrawn[bdi] = beam.cid
          bdi = bdi + 1
        end
      end
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(255, 0, 0, 255), "Compression")
      drawLegendText(color(0, 0, 255, 255), "Extension")
    end

  -- "stress (new)"
  elseif modeID == 9 then
    local scaler = 1 / (rangeMax - rangeMin)

    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        local stress = obj:getBeamStressDamp(beam.cid)
        local absStress = abs(stress)

        if mode.rangeMinEnabled and mode.rangeMaxEnabled then
          if mode.usesInclusiveRange and absStress >= rangeMin and absStress <= rangeMax
          or not mode.usesInclusiveRange and absStress > rangeMin and absStress < rangeMax then
            local a = (absStress - rangeMin) * scaler * 255
            if a > 5 then
              local r = max(-1, min(0, (stress + rangeMin) * scaler)) * 255 * -1 -- (red compression)
              local b = max(0, min(1, (stress - rangeMin) * scaler)) * 255 -- (blue extension)
              a = a * alpha
              obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, 0, b, a))

              beamsDrawn[bdi] = beam.cid
              bdi = bdi + 1
            end
          end
        elseif not mode.rangeMinEnabled and not mode.rangeMaxEnabled
        or mode.rangeMinEnabled and (mode.usesInclusiveRange and absStress >= rangeMin or not mode.usesInclusiveRange and absStress > rangeMin)
        or mode.rangeMaxEnabled and (mode.usesInclusiveRange and absStress <= rangeMax or not mode.usesInclusiveRange and absStress < rangeMax) then
          local r = stress < 0 and 255 or 0
          local b = stress >= 0 and 255 or 0
          obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, 0, b, alpha * 255))

          beamsDrawn[bdi] = beam.cid
          bdi = bdi + 1
        end
      end
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(255, 0, 0, 255), "Compression")
      drawLegendText(color(0, 0, 255, 255), "Extension")
      drawLegendText(color(255, 255, 255, 255), stringFormat("Range Min: %.2f", rangeMin))
      drawLegendText(color(255, 255, 255, 255), stringFormat("Range Max: %.2f", rangeMax))
    end

  -- "displacement"
  elseif modeID == 10 then
    local scaler = 1 / (rangeMax - rangeMin)

    local nodePosCache = {}

    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        tempVec:setSub2(v.data.nodes[beam.id2].pos, v.data.nodes[beam.id1].pos)
        local originalLength = tempVec:length()

        local nodePos1 = nodePosCache[beam.id1] or obj:getNodePosition(beam.id1)
        local nodePos2 = nodePosCache[beam.id2] or obj:getNodePosition(beam.id2)
        nodePosCache[beam.id1] = nodePos1
        nodePosCache[beam.id2] = nodePos2

        tempVec:setSub2(nodePos2, nodePos1)
        local currentLength = tempVec:length()
        local displacement = currentLength - originalLength
        local absDisplacement = abs(displacement)

        if mode.rangeMinEnabled and mode.rangeMaxEnabled then
          if mode.usesInclusiveRange and absDisplacement >= rangeMin and absDisplacement <= rangeMax
          or not mode.usesInclusiveRange and absDisplacement > rangeMin and absDisplacement < rangeMax then
            local a = (absDisplacement - rangeMin) * scaler * 255
            if a > 5 then
              local r = max(-1, min(0, (displacement + rangeMin) * scaler)) * 255 * -1 -- (red compression)
              local b = max(0, min(1, (displacement - rangeMin) * scaler)) * 255 -- (blue extension)
              a = a * alpha
              obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, 0, b, a))

              beamsDrawn[bdi] = beam.cid
              bdi = bdi + 1
            end
          end
        elseif not mode.rangeMinEnabled and not mode.rangeMaxEnabled
        or mode.rangeMinEnabled and (mode.usesInclusiveRange and absDisplacement >= rangeMin or not mode.usesInclusiveRange and absDisplacement > rangeMin)
        or mode.rangeMaxEnabled and (mode.usesInclusiveRange and absDisplacement <= rangeMax or not mode.usesInclusiveRange and absDisplacement < rangeMax) then
          local r = displacement < 0 and 255 or 0
          local b = displacement >= 0 and 255 or 0
          obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, 0, b, alpha * 255))

          beamsDrawn[bdi] = beam.cid
          bdi = bdi + 1
        end
      end
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(255, 0, 0, 255), "Compression")
      drawLegendText(color(0, 0, 255, 255), "Extension")
      drawLegendText(color(255, 255, 255, 255),  stringFormat("Range Min: %.2f", rangeMin))
      drawLegendText(color(255, 255, 255, 255),  stringFormat("Range Max: %.2f", rangeMax))
    end

  -- "deformation"
  elseif modeID == 11 then
    local deformRange = rangeMax - rangeMin
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      local deform = obj:getBeamDebugDeformation(beam.cid) - 1
      local deformGroup = beam.deformGroup

      if not beamsDeformed[i] and deform ~= 0 then
        printBeamDeformed(i)
        beamsDeformed[i] = true
      end
      if deformGroup and beamstate.deformGroupsTriggerBeam[deformGroup] and not deformGroupsTriggerDisplayed[deformGroup] then
        printBeamDeformGroupTriggered(deformGroup, beamstate.deformGroupsTriggerBeam[deformGroup])
        deformGroupsTriggerDisplayed[deformGroup] = true
      end

      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        if not obj:beamIsBroken(beam.cid) then
          local absDeform = abs(deform)

          if mode.rangeMinEnabled and mode.rangeMaxEnabled then
            if mode.usesInclusiveRange and absDeform >= rangeMin and absDeform <= rangeMax
            or not mode.usesInclusiveRange and absDeform > rangeMin and absDeform < rangeMax then
              local r = max(min((-deform - rangeMin) / deformRange, 1), 0) * 255
                --red for compression
              local b = max(min((deform - rangeMin) / deformRange, 1), 0) * 255
                --blue for elongation
              local a = min((absDeform - rangeMin) / deformRange, 1) * 255 * alpha
              obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, 0, b, a))

              beamsDrawn[bdi] = beam.cid
              bdi = bdi + 1
            end
          elseif not mode.rangeMinEnabled and not mode.rangeMaxEnabled
          or mode.rangeMinEnabled and (mode.usesInclusiveRange and absDeform >= rangeMin or not mode.usesInclusiveRange and absDeform > rangeMin)
          or mode.rangeMaxEnabled and (mode.usesInclusiveRange and absDeform <= rangeMax or not mode.usesInclusiveRange and absDeform < rangeMax) then
            local r = deform < 0 and 255 or 0
            local b = deform >= 0 and 255 or 0
            obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, 0, b, alpha * 255))

            beamsDrawn[bdi] = beam.cid
            bdi = bdi + 1
          end
        end
      end
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(255, 0, 0, 255), "Compression")
      drawLegendText(color(0, 0, 255, 255), "Extension")
      drawLegendText(color(255, 255, 255, 255),  stringFormat("Range Min: %.2f", rangeMin))
      drawLegendText(color(255, 255, 255, 255),  stringFormat("Range Max: %.2f", rangeMax))
    end

  -- "breakgroups"
  elseif modeID == 12 then
    tempVec:set(0,0,0)
    local j = 0
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        if beam.breakGroup and beam.breakGroup ~= "" then
          local breakGroups = type(beam.breakGroup) == "table" and beam.breakGroup or {beam.breakGroup}
          for _, g in pairs(breakGroups) do
            if not groupsData[g] then
              groupsData[g] = {0, vec3(), getContrastColor(j, 255 * alpha)}
              j = j + 1
            end
            local groupData = groupsData[g]

            if beamstate.brokenBreakGroups[g] and not brokenBreakGroupsDisplayed[g] then
              printBreakGroupBroken(g)
              brokenBreakGroupsDisplayed[g] = true
            end

            local pos1, pos2 = obj:getAbsNodePosition(beam.id1), obj:getAbsNodePosition(beam.id2)
            tempVec:setAdd2(pos1, pos2)
            tempVec:setScaled(0.5)
            groupData[1] = groupData[1] + 1
            groupData[2]:setAdd(tempVec)
            obj.debugDrawProxy:drawCylinder(pos1, pos2, beamScale, groupData[3])
            beamsDrawn[bdi] = beam.cid
            bdi = bdi + 1
          end
        end
      end
    end
    for g, groupData in pairs(groupsData) do
      local groupPos = groupData[2]
      groupPos:setScaled(1 / groupData[1])
      obj.debugDrawProxy:drawText(groupPos, groupData[3], g)
    end
    tableClear(groupsData)

  -- "deformgroups"
  elseif modeID == 13 then
    tempVec:set(0,0,0)
    local j = 0
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      local deform = obj:getBeamDebugDeformation(beam.cid) - 1
      local deformGroup = beam.deformGroup

      if not beamsDeformed[i] and deform ~= 0 then
        printBeamDeformed(i)
        beamsDeformed[i] = true
      end
      if deformGroup and beamstate.deformGroupsTriggerBeam[deformGroup] and not deformGroupsTriggerDisplayed[deformGroup] then
        printBeamDeformGroupTriggered(deformGroup, beamstate.deformGroupsTriggerBeam[deformGroup])
        deformGroupsTriggerDisplayed[deformGroup] = true
      end

      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        if beam.deformGroup and beam.deformGroup ~= "" then
          local deformGroups = type(beam.deformGroup) == "table" and beam.deformGroup or {beam.deformGroup}
          for _, g in pairs(deformGroups) do
            if not groupsData[g] then
              groupsData[g] = {0, vec3(), getContrastColor(j, 255 * alpha)}
              j = j + 1
            end
            local groupData = groupsData[g]
            local pos1, pos2 = obj:getAbsNodePosition(beam.id1), obj:getAbsNodePosition(beam.id2)
            tempVec:setAdd2(pos1, pos2)
            tempVec:setScaled(0.5)
            groupData[1] = groupData[1] + 1
            groupData[2]:setAdd(tempVec)
            obj.debugDrawProxy:drawCylinder(pos1, pos2, beamScale, groupData[3])
            beamsDrawn[bdi] = beam.cid
            bdi = bdi + 1
          end
        end
      end
    end
    for g, groupData in pairs(groupsData) do
      local groupPos = groupData[2]
      groupPos:setScaled(1 / groupData[1])
      obj.debugDrawProxy:drawText(groupPos, groupData[3], g)
    end
    tableClear(groupsData)

  -- "boundedBeamBounds"
  elseif modeID == 14 then
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if beam.beamType == BEAM_BOUNDED then
        if partsSelected[beam.partPath or v.config.partsTree.partPath] then
          local newBeamScale = beamScale * (0.5 + bdi * 0.01)

          local currLen = obj:getBeamLength(beam.cid)
          local restLen = obj:getBeamRefLength(beam.cid)
          local restLenHalf = restLen * 0.5
          local node1Pos = obj:getAbsNodePosition(beam.id1)
          local node2Pos = obj:getAbsNodePosition(beam.id2)
          local middlePos = (node1Pos + node2Pos) * 0.5
          local node1to2Dir = (node2Pos - node1Pos):normalized()
          local restPos1 = -node1to2Dir * restLenHalf + middlePos
          local restPos2 = node1to2Dir * restLenHalf + middlePos

          local boundZone = type(beam.boundZone) == 'number' and beam.boundZone or 1

          local shortBoundTransEnd = type(beam.shortBoundRange) == 'number' and max(restLen - max(0, beam.shortBoundRange) - boundZone, 0) or max((restLen * max(1 - max(0, beam.beamShortBound or 1)) - boundZone), 0)
          local shortBoundTransStart = type(beam.shortBoundRange) == 'number' and max(restLen - max(0, beam.shortBoundRange), 0) or restLen * max((1 - max(0, beam.beamShortBound or 1)), 0)

          local longBoundTransStart = type(beam.longBoundRange) == 'number' and restLen + max(0, beam.longBoundRange) or restLen * (1 + max(0, beam.beamLongBound or 1))
          local longBoundTransEnd = type(beam.longBoundRange) == 'number' and max(restLen + max(0, beam.longBoundRange) + boundZone, 0) or max((restLen * (1 + max(0, beam.beamLongBound or 1)) + boundZone), 0)

          if currLen < shortBoundTransEnd then
            local shortBoundTransEndPos1 = -node1to2Dir * shortBoundTransEnd * 0.5 + middlePos
            local shortBoundTransStartPos1 = -node1to2Dir * shortBoundTransStart * 0.5 + middlePos

            local shortBoundTransEndPos2 = node1to2Dir * shortBoundTransEnd * 0.5 + middlePos
            local shortBoundTransStartPos2 = node1to2Dir * shortBoundTransStart * 0.5 + middlePos

            obj.debugDrawProxy:drawCylinder(restPos1, shortBoundTransStartPos1, newBeamScale, color(0,0,255,255 * alpha))
            obj.debugDrawProxy:drawCylinder(shortBoundTransStartPos1, shortBoundTransEndPos1, newBeamScale, color(0,128,255,255 * alpha))
            obj.debugDrawProxy:drawCylinder(shortBoundTransEndPos1, node1Pos, newBeamScale, color(0,255,255,255 * alpha))

            obj.debugDrawProxy:drawCylinder(node1Pos, node2Pos, newBeamScale, color(0,255,0,255 * alpha))

            obj.debugDrawProxy:drawCylinder(node2Pos, shortBoundTransEndPos2, newBeamScale, color(0,255,255,255 * alpha))
            obj.debugDrawProxy:drawCylinder(shortBoundTransEndPos2, shortBoundTransStartPos2, newBeamScale, color(0,128,255,255 * alpha))
            obj.debugDrawProxy:drawCylinder(shortBoundTransStartPos2, restPos2, newBeamScale, color(0,0,255,255 * alpha))

          elseif currLen < shortBoundTransStart then
            local shortBoundTransStartPos1 = -node1to2Dir * shortBoundTransStart * 0.5 + middlePos

            local shortBoundTransStartPos2 = node1to2Dir * shortBoundTransStart * 0.5 + middlePos

            obj.debugDrawProxy:drawCylinder(restPos1, shortBoundTransStartPos1, newBeamScale, color(0,0,255,255 * alpha))
            obj.debugDrawProxy:drawCylinder(shortBoundTransStartPos1, node1Pos, newBeamScale, color(0,128,255,255 * alpha))

            obj.debugDrawProxy:drawCylinder(node1Pos, node2Pos, newBeamScale, color(0,255,0,255 * alpha))

            obj.debugDrawProxy:drawCylinder(node2Pos, shortBoundTransStartPos2, newBeamScale, color(0,128,255,255 * alpha))
            obj.debugDrawProxy:drawCylinder(shortBoundTransStartPos2, restPos2, newBeamScale, color(0,0,255,255 * alpha))

          elseif currLen < restLen then
            obj.debugDrawProxy:drawCylinder(restPos1, node1Pos, newBeamScale, color(0,0,255,255 * alpha))

            obj.debugDrawProxy:drawCylinder(node1Pos, node2Pos, newBeamScale, color(0,255,0,255 * alpha))

            obj.debugDrawProxy:drawCylinder(node2Pos, restPos2, newBeamScale, color(0,0,255,255 * alpha))

          elseif currLen < longBoundTransStart then
            obj.debugDrawProxy:drawCylinder(node1Pos, restPos1, newBeamScale, color(255,0,0,255 * alpha))

            obj.debugDrawProxy:drawCylinder(restPos1, restPos2, newBeamScale, color(0,255,0,255 * alpha))

            obj.debugDrawProxy:drawCylinder(restPos2, node2Pos, newBeamScale, color(255,0,0,255 * alpha))

          elseif currLen < longBoundTransEnd then
            local longBoundTransStartPos1 = -node1to2Dir * longBoundTransStart * 0.5 + middlePos

            local longBoundTransStartPos2 = node1to2Dir * longBoundTransStart * 0.5 + middlePos

            obj.debugDrawProxy:drawCylinder(node1Pos, longBoundTransStartPos1, newBeamScale, color(255,128,0,255 * alpha))
            obj.debugDrawProxy:drawCylinder(longBoundTransStartPos1, restPos1, newBeamScale, color(255,0,0,255 * alpha))

            obj.debugDrawProxy:drawCylinder(restPos1, restPos2, newBeamScale, color(0,255,0,255 * alpha))

            obj.debugDrawProxy:drawCylinder(restPos2, longBoundTransStartPos2, newBeamScale, color(255,0,0,255 * alpha))
            obj.debugDrawProxy:drawCylinder(longBoundTransStartPos2, node2Pos, newBeamScale, color(255,128,0,255 * alpha))
          else
            local longBoundTransEndPos1 = -node1to2Dir * longBoundTransEnd * 0.5 + middlePos
            local longBoundTransStartPos1 = -node1to2Dir * longBoundTransStart * 0.5 + middlePos

            local longBoundTransEndPos2 = node1to2Dir * longBoundTransEnd * 0.5 + middlePos
            local longBoundTransStartPos2 = node1to2Dir * longBoundTransStart * 0.5 + middlePos

            obj.debugDrawProxy:drawCylinder(node1Pos, longBoundTransEndPos1, newBeamScale, color(255,255,0,255 * alpha))
            obj.debugDrawProxy:drawCylinder(longBoundTransEndPos1, longBoundTransStartPos1, newBeamScale, color(255,128,0,255 * alpha))
            obj.debugDrawProxy:drawCylinder(longBoundTransStartPos1, restPos1, newBeamScale, color(255,0,0,255 * alpha))

            obj.debugDrawProxy:drawCylinder(restPos1, restPos2, newBeamScale, color(0,255,0,255 * alpha))

            obj.debugDrawProxy:drawCylinder(restPos2, longBoundTransStartPos2, newBeamScale, color(255,0,0,255 * alpha))
            obj.debugDrawProxy:drawCylinder(longBoundTransStartPos2, longBoundTransEndPos2, newBeamScale, color(255,128,0,255 * alpha))
            obj.debugDrawProxy:drawCylinder(longBoundTransEndPos2, node2Pos, newBeamScale, color(255,255,0,255 * alpha))
          end

          beamsDrawn[bdi] = beam.cid
          bdi = bdi + 1
        end
      end
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(0,255,255,255), "Short Bound")
      drawLegendText(color(0,128,255,255), "Short Bound Transition")
      drawLegendText(color(0,0,255,255), "Contraction")
      drawLegendText(color(0,255,0,255), "Beam")
      drawLegendText(color(255,0,0,255), "Expansion")
      drawLegendText(color(255,128,0,255), "Long Bound Transition")
      drawLegendText(color(255,255,0,255), "Long Bound")
    end

  -- "supportBeamBounds"
  elseif modeID == 15 then
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if beam.beamType == BEAM_SUPPORT then
        if partsSelected[beam.partPath or v.config.partsTree.partPath] then
          local currLen = obj:getBeamLength(beam.cid)
          local restLen = obj:getBeamRefLength(beam.cid)
          local restLenHalf = restLen * 0.5
          local node1Pos = obj:getAbsNodePosition(beam.id1)
          local node2Pos = obj:getAbsNodePosition(beam.id2)
          local middlePos = (node1Pos + node2Pos) * 0.5
          local node1to2Dir = (node2Pos - node1Pos):normalized()
          local dirPerp = node1to2Dir:perpendicularN()
          local restLenCol = currLen >= restLen and color(255, 0, 0, alpha * 255 * 0.33) or color(0, 0, 255, alpha * 255 * 0.33)

          local longBoundHalfLen = type(beam.beamLongExtent) == 'number' and (restLen + max(0, beam.beamLongExtent)) * 0.5 or restLen * (1 + max(0, beam.beamLongBound or 1)) * 0.5

          --cylinder representing long bound
          obj.debugDrawProxy:drawCylinder(-node1to2Dir * longBoundHalfLen + middlePos + dirPerp * 0.005, node1to2Dir * longBoundHalfLen + middlePos + dirPerp * 0.005, beamScale * 1, color(255, 255, 0, alpha * 255 * 0.5))

          -- beam representing rest length
          obj.debugDrawProxy:drawCylinder(-node1to2Dir * restLenHalf + middlePos, node1to2Dir * restLenHalf + middlePos, beamScale, restLenCol)

          -- beam representing full length
          obj.debugDrawProxy:drawCylinder(node1Pos, node2Pos, beamScale * 0.5, color(0, 255, 0, alpha * 255))

          beamsDrawn[bdi] = beam.cid
          bdi = bdi + 1
        end
      end
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(0, 0, 255, 255), "Contraction")
      drawLegendText(color(255, 0, 0, 255), "Expansion")
    end

  -- frequency
  elseif modeID == 16 then
    local freq, ampMax = mode.sliders[1].val, mode.sliders[2].val
    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        local amplitude = obj:getBeamFrequencyAmplitude(i, freq, 10) --obj:detectBeamFrequency(i)
        beamFreqModeAmp[i] = amplitude --0.5 * beam.beamSpring * amplitude^2
      end
    end
    local ampScaler = 1 / ampMax
    for beamID, energy in pairs(beamFreqModeAmp) do
      local a = min(255, energy * ampScaler * 255 * alpha)
      obj.debugDrawProxy:drawBeam3d(beamID, beamScale, color(255, 0, 0, a))
      beamsDrawn[bdi] = beamID
      bdi = bdi + 1
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(0, 0, 0, 255), stringFormat("%.2f Hz", freq))
      drawLegendText(color(0, 0, 0, 255), stringFormat("Max Amplitude: %.2f m", ampMax))
    end

    tableClear(beamFreqModeAmp)

  -- the rest
  elseif modeID >= 17 then
    -- Do rendering and get min/max values for next frame rendering
    local scaler = 1 / (rangeMax - rangeMin)

    for i = 0, beamsCount - 1 do
      local beam = v.data.beams[i]
      if partsSelected[beam.partPath or v.config.partsTree.partPath] then
        local val = tonumber(beam[modeName])
        if val then
          minVal = val ~= -huge and min(val, minVal) or minVal
          maxVal = val ~= huge and max(val, maxVal) or maxVal

          if abs(val) == huge then
            if mode.showInfinity then
              local a = alpha * 255
              obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(255, 0, 255, a))

              beamsDrawn[bdi] = beam.cid
              bdi = bdi + 1
            end
          else
            if mode.rangeMinEnabled and mode.rangeMaxEnabled then
              if mode.usesInclusiveRange and val >= rangeMin and val <= rangeMax
              or not mode.usesInclusiveRange and val > rangeMin and val < rangeMax then
                local relValue = scaler * (val - rangeMin)

                local r = (relValue + (1 - relValue)) * 255
                local g = (1 - relValue) * 255
                local b = (1 - relValue) * 255
                local a = alpha * 255

                obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(r, g, b, a))

                beamsDrawn[bdi] = beam.cid
                bdi = bdi + 1
              end
            elseif not mode.rangeMinEnabled and not mode.rangeMaxEnabled
            or mode.rangeMinEnabled and (mode.usesInclusiveRange and val >= rangeMin or not mode.usesInclusiveRange and val > rangeMin)
            or mode.rangeMaxEnabled and (mode.usesInclusiveRange and val <= rangeMax or not mode.usesInclusiveRange and val < rangeMax) then
              obj.debugDrawProxy:drawBeam3d(beam.cid, beamScale, color(255, 0, 0, alpha * 255))

              beamsDrawn[bdi] = beam.cid
              bdi = bdi + 1
            end
          end
        end
      end
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(255, 255, 255, 255), stringFormat("Range Min: %.2f", rangeMin))
      drawLegendText(color(255, 0, 0, 255),     stringFormat("Range Max: %.2f", rangeMax))
      if mode.showInfinity then
        drawLegendText(color(255, 0, 255, 255),  "Includes FLT_MAX")
      end
    end
  end

  -- If auto range enabled and at least one beam value exists, use it to calculate range min/max values
  if mode.autoRange and minVal ~= huge and maxVal ~= -huge then
    if not mode.rangeMinCap or (mode.rangeMinCap and minVal < mode.rangeMinCap) then
      mode.rangeMinCap = minVal
      dirty = true
    end

    if not mode.rangeMaxCap or (mode.rangeMaxCap and maxVal > mode.rangeMaxCap) then
      mode.rangeMaxCap = maxVal

      if mode.rangeMinCap == mode.rangeMaxCap then
        local magnitude = math.floor(math.log10(abs(mode.rangeMaxCap)))

        mode.rangeMaxCap = mode.rangeMaxCap + math.pow(10, magnitude - 1)
      end

      dirty = true
    end

    if not mode.rangeMin then
      mode.rangeMin = mode.rangeMinCap
      dirty = true
    end

    if not mode.rangeMax then
      mode.rangeMax = mode.rangeMaxCap
      dirty = true
    end
  end

  if requestDrawnBeamsCallbacks and next(requestDrawnBeamsCallbacks) ~= nil then
    for _, geFuncName in ipairs(requestDrawnBeamsCallbacks) do
      obj:queueGameEngineLua(stringFormatWorkBuffer("%s(%s,%f)", geFuncName, serializeWorkBuffer(beamsDrawn), beamScale))
    end
    tableClear(requestDrawnBeamsCallbacks)
  end

  return dirty
end

local function drawTorsionBar(torbar, nodeScale, beamScale, alpha, color1, color2)
  color2 = color2 or color1

  local r,g,b,a = colorGetRGBA(color1)
  color1 = color(r, g, b, alpha)

  local r,g,b,a = colorGetRGBA(color2)
  color2 = color(r, g, b, alpha)

  local id1, id2, id3, id4 = torbar.id1, torbar.id2, torbar.id3, torbar.id4

  if id1 and id2 and id3 and id4 then
    local node1Pos = obj:getAbsNodePosition(id1)
    local node2Pos = obj:getAbsNodePosition(id2)
    local node3Pos = obj:getAbsNodePosition(id3)
    local node4Pos = obj:getAbsNodePosition(id4)

    obj.debugDrawProxy:drawNodeSphere(id1, nodeScale, color(255, 0, 0, alpha))
    obj.debugDrawProxy:drawNodeSphere(id2, nodeScale, color(255, 125, 0, alpha))
    obj.debugDrawProxy:drawNodeSphere(id3, nodeScale, color(255, 255, 0, alpha))
    obj.debugDrawProxy:drawNodeSphere(id4, nodeScale, color(0, 255, 0, alpha))

    -- obj.debugDrawProxy:drawCylinder(node1Pos, node2Pos, beamScale, col)
    -- obj.debugDrawProxy:drawCylinder(node2Pos, node3Pos, beamScale, col)
    -- obj.debugDrawProxy:drawCylinder(node3Pos, node4Pos, beamScale, col)

    -- triangle 1
    obj.debugDrawProxy:drawCylinder(node1Pos, node2Pos, beamScale, color1)
    obj.debugDrawProxy:drawCylinder(node1Pos, node3Pos, beamScale, color1)

    --obj.debugDrawProxy:drawNodeTriangle(id1, id2, id3, 0, color(255, 0, 255, alpha * 0.5))

    -- triangle 2
    obj.debugDrawProxy:drawCylinder(node4Pos, node2Pos, beamScale, color2)
    obj.debugDrawProxy:drawCylinder(node4Pos, node3Pos, beamScale, color2)

    --obj.debugDrawProxy:drawNodeTriangle(id4, id2, id3, 0, color(0, 255, 255, alpha * 0.5))

    -- axis
    obj.debugDrawProxy:drawCylinder(node2Pos, node3Pos, beamScale * 4, color(255, 128, 0, alpha))
  end
end

local function visualizeTorsionBars()
  local dirty = false

  local partsSelected = M.partsState.partsSelected

  local modeID = M.state.vehicle.torsionBarVisMode
  local mode = M.state.vehicle.torsionBarVisModes[modeID]
  if not mode then return false end

  local modeName = mode.name

  local rangeMin = mode.rangeMin or -huge
  local rangeMax = mode.rangeMax or huge

  local minVal = huge
  local maxVal = -huge

  local nodeScale = 0.02 * M.state.vehicle.torsionBarVisWidthScale
  local beamScale = math.max(0.01 * M.state.vehicle.torsionBarVisWidthScale - 0.008, 0.00025)
  local alpha = M.state.vehicle.torsionBarVisAlpha * 255

  -- "off"
  if modeID == 1 then return dirty end

  if playerInfo.firstPlayerSeated then
    nextLegendColumn()
    drawLegendText(color(255, 165, 0, 255), "Torsion Bar Vis Mode: " .. modeName)
  end

  -- "simple"
  if modeID == 2 then
    for i = 0, torsionBarsCount - 1 do
      local torbar = v.data.torsionbars[i]
      if partsSelected[torbar.partPath or v.config.partsTree.partPath] then
        drawTorsionBar(torbar, nodeScale, beamScale, alpha, unpack(torbarTypesColors[TORBAR_NORMAL]))
      end
    end

  -- "type"
  elseif modeID == 3 then
    for i = 0, torsionBarsCount - 1 do
      local torbar = v.data.torsionbars[i]
      if partsSelected[torbar.partPath or v.config.partsTree.partPath] then
        local col1, col2
        if torbar.spring2 or torbar.damp2 then
          -- anisotropic torsionbar
          col1, col2 = unpack(torbarTypesColors[TORBAR_ANISOTROPIC])
        else
          -- regular torsionbar
          col1, col2 = unpack(torbarTypesColors[TORBAR_NORMAL])
        end

        drawTorsionBar(torbar, nodeScale, beamScale, alpha, col1, col2)
      end
    end

    -- Color legend
    if playerInfo.firstPlayerSeated then
      for i = 1, #torbarTypesNames do
        if i ~= TORBAR_BROKEN then
          drawLegendText(torbarTypesColors[i][1], torbarTypesNames[i])
        end
      end
    end

  -- "withoutBroken", "withBroken", "brokenOnly"
  elseif modeID == 4 or modeID == 5 or modeID == 6 then
    for i = 0, torsionBarsCount - 1 do
      local torbar = v.data.torsionbars[i]
      if partsSelected[torbar.partPath or v.config.partsTree.partPath] then
        local torbarBroken = obj:torsionbarIsBroken(torbar.cid)
        if (modeID == 4 and not torbarBroken) or modeID == 5 or (modeID == 6 and torbarBroken) then
          --local startAngle, endAngle = 0, 0
          local col1, col2
          local sizeMult = 1

          if not torbarBroken then
            if torbar.spring2 or torbar.damp2 then
              -- anisotropic torsionbar, purple blue shade
              col1, col2 = unpack(torbarTypesColors[TORBAR_ANISOTROPIC])
            else
              -- regular torsionbar, green-cyan shade
              col1, col2 = unpack(torbarTypesColors[TORBAR_NORMAL])
            end
          else
            -- broken ones will have red-orange shade
            col1, col2 = unpack(torbarTypesColors[TORBAR_BROKEN])
            sizeMult = 2
          end

          --local col = jetColor((startAngle + (endAngle - startAngle) * torbar.cid / (torsionBarsCount+1))/ 360, alpha)
          drawTorsionBar(torbar, nodeScale * sizeMult, beamScale * sizeMult, alpha, col1, col2)
        end
      end
    end

    -- Color legend
    if playerInfo.firstPlayerSeated then
      for i = 1, #torbarTypesNames do
        drawLegendText(torbarTypesColors[i][1], torbarTypesNames[i])
      end
    end

  -- "angle"
  elseif modeID == 7 then
    local scaler = 1 / (rangeMax - rangeMin)

    for i = 0, torsionBarsCount - 1 do
      local torbar = v.data.torsionbars[i]
      if partsSelected[torbar.partPath or v.config.partsTree.partPath] then
        local id1, id2, id3, id4 = torbar.id1, torbar.id2, torbar.id3, torbar.id4

        if id1 and id2 and id3 and id4 then
          local angle = math.abs(obj:getTorsionbarAngle(i)) * 180.0 / math.pi

          if mode.rangeMinEnabled and mode.rangeMaxEnabled then
            if mode.usesInclusiveRange and angle >= rangeMin and angle <= rangeMax
            or not mode.usesInclusiveRange and angle > rangeMin and angle < rangeMax then
              local a = min((angle - rangeMin) * scaler, 1) * alpha
              drawTorsionBar(torbar, nodeScale, beamScale, a, color(0,255,0,255), color(0,255,255,255))
            end
          elseif not mode.rangeMinEnabled and not mode.rangeMaxEnabled
          or mode.rangeMinEnabled and (mode.usesInclusiveRange and angle >= rangeMin or not mode.usesInclusiveRange and angle > rangeMin)
          or mode.rangeMaxEnabled and (mode.usesInclusiveRange and angle <= rangeMax or not mode.usesInclusiveRange and angle < rangeMax) then
            drawTorsionBar(torbar, nodeScale, beamScale, alpha, color(255,0,0,255), color(255,128,0,255))
          end
        end
      end
    end

  -- "stress"
  elseif modeID == 8 then
    local scaler = 1 / (rangeMax - rangeMin)

    for i = 0, torsionBarsCount - 1 do
      local torbar = v.data.torsionbars[i]
      if partsSelected[torbar.partPath or v.config.partsTree.partPath] then
        local id1, id2, id3, id4 = torbar.id1, torbar.id2, torbar.id3, torbar.id4

        if id1 and id2 and id3 and id4 then
          local stress = math.abs(obj:getTorsionbarAngle(i)) * torbar.spring

          if mode.rangeMinEnabled and mode.rangeMaxEnabled then
            if mode.usesInclusiveRange and stress >= rangeMin and stress <= rangeMax
            or not mode.usesInclusiveRange and stress > rangeMin and stress < rangeMax then
              local a = min((stress - rangeMin) * scaler, 1) * alpha
              drawTorsionBar(torbar, nodeScale, beamScale, a, color(0,255,0,255), color(0,255,255,255))
            end
          elseif not mode.rangeMinEnabled and not mode.rangeMaxEnabled
          or mode.rangeMinEnabled and (mode.usesInclusiveRange and stress >= rangeMin or not mode.usesInclusiveRange and stress > rangeMin)
          or mode.rangeMaxEnabled and (mode.usesInclusiveRange and stress <= rangeMax or not mode.usesInclusiveRange and stress < rangeMax) then
            drawTorsionBar(torbar, nodeScale, beamScale, alpha, color(255,0,0,255), color(255,128,0,255))
          end
        end
      end
    end

  -- "deformation"
  elseif modeID == 9 then
    local deformRange = rangeMax - rangeMin
    for i = 0, torsionBarsCount - 1 do
      local torbar = v.data.torsionbars[i]
      if partsSelected[torbar.partPath or v.config.partsTree.partPath] then
        local id1, id2, id3, id4 = torbar.id1, torbar.id2, torbar.id3, torbar.id4
        if id1 and id2 and id3 and id4 then
          local deform = obj:getTorsionbarDeformation(i)
          local absDeform = abs(deform)

          if mode.rangeMinEnabled and mode.rangeMaxEnabled then
            if mode.usesInclusiveRange and absDeform >= rangeMin and absDeform <= rangeMax
            or not mode.usesInclusiveRange and absDeform > rangeMin and absDeform < rangeMax then
              local r = max(min((-deform - rangeMin) / deformRange, 1), 0) * 255
                --red for compression
              local b = max(min((deform - rangeMin) / deformRange, 1), 0) * 255
                --blue for elongation
              local a = min((absDeform - rangeMin) / deformRange, 1) * alpha
              drawTorsionBar(torbar, nodeScale, beamScale, a, color(r, 0, b, a))
            end
          elseif not mode.rangeMinEnabled and not mode.rangeMaxEnabled
          or mode.rangeMinEnabled and (mode.usesInclusiveRange and absDeform >= rangeMin or not mode.usesInclusiveRange and absDeform > rangeMin)
          or mode.rangeMaxEnabled and (mode.usesInclusiveRange and absDeform <= rangeMax or not mode.usesInclusiveRange and absDeform < rangeMax) then
            local r = deform < 0 and 255 or 0
            local b = deform >= 0 and 255 or 0
            drawTorsionBar(torbar, nodeScale, beamScale, alpha, color(r, 0, b, alpha))
          end
        end
      end
    end

  -- the rest
  elseif modeID >= 10 then
    -- Do rendering and get min/max values for next frame rendering
    local scaler = 1 / (rangeMax - rangeMin)

    for i = 0, torsionBarsCount - 1 do
      local torbar = v.data.torsionbars[i]
      if partsSelected[torbar.partPath or v.config.partsTree.partPath] then
        local val = tonumber(torbar[modeName])

        if val then
          minVal = val ~= -huge and min(val, minVal) or minVal
          maxVal = val ~= huge and max(val, maxVal) or maxVal

          if abs(val) == huge then
            if mode.showInfinity then
              local sizeMult = 1
              -- For 'spring' visualization mode, also set scale of nodes/beams
              if modeName == 'spring' then
                sizeMult = 3
              end
              drawTorsionBar(torbar, nodeScale * sizeMult, beamScale * sizeMult, alpha, color(255, 0, 255, alpha))
            end
          else
            if mode.rangeMinEnabled and mode.rangeMaxEnabled then
              if mode.usesInclusiveRange and val >= rangeMin and val <= rangeMax
              or not mode.usesInclusiveRange and val > rangeMin and val < rangeMax then
                local relValue = scaler * (val - rangeMin)
                --if not isnan(relValue) then
                local r = (relValue + (1 - relValue)) * 255
                local g = (1 - relValue) * 255
                local b = (1 - relValue) * 255

                local sizeMult = 1
                -- For 'spring' visualization mode, also set scale of nodes/beams
                if modeName == 'spring' then
                  sizeMult = relValue * 1.5 + 1
                end

                drawTorsionBar(torbar, nodeScale * sizeMult, beamScale * sizeMult, alpha, color(r, g, b, alpha))
                --end
              end
            elseif not mode.rangeMinEnabled and not mode.rangeMaxEnabled
            or mode.rangeMinEnabled and (mode.usesInclusiveRange and val >= rangeMin or not mode.usesInclusiveRange and val > rangeMin)
            or mode.rangeMaxEnabled and (mode.usesInclusiveRange and val <= rangeMax or not mode.usesInclusiveRange and val < rangeMax) then
              drawTorsionBar(torbar, nodeScale, beamScale, alpha, color(255, 0, 0, alpha))
            end
          end
        end
      end
    end

    if playerInfo.firstPlayerSeated then
      drawLegendText(color(255, 255, 255, 255), stringFormat("Range Min: %.2f", rangeMin))
      drawLegendText(color(255, 0, 0, 255),     stringFormat("Range Max: %.2f", rangeMax))
      if mode.showInfinity then
        drawLegendText(color(255, 0, 255, 255),  "Includes FLT_MAX")
      end
    end
  end

  -- If auto range enabled and at least one torsionbar value exists, use it to calculate range min/max values
  if mode.autoRange and minVal ~= huge and maxVal ~= -huge then
    if not mode.rangeMinCap or (mode.rangeMinCap and minVal < mode.rangeMinCap) then
      mode.rangeMinCap = minVal
      dirty = true
    end

    if not mode.rangeMaxCap or (mode.rangeMaxCap and maxVal > mode.rangeMaxCap) then
      mode.rangeMaxCap = maxVal

      if mode.rangeMinCap == mode.rangeMaxCap then
        local magnitude = math.floor(math.log10(abs(mode.rangeMaxCap)))

        mode.rangeMaxCap = mode.rangeMaxCap + math.pow(10, magnitude - 1)
      end

      dirty = true
    end

    if not mode.rangeMin then
      mode.rangeMin = mode.rangeMinCap
      dirty = true
    end

    if not mode.rangeMax then
      mode.rangeMax = mode.rangeMaxCap
      dirty = true
    end
  end

  return dirty
end

local function drawRailSlidenodes(rail, slidenodes, nodeScale, beamScale, slideNodeScale, defaultCol, linkColorsSizes)
  -- Draw Rail
  local links = rail['links:']
  local linksNodeCount = #links

  for i = 2, linksNodeCount do
    local prevNodeCID = links[i - 1]
    local nodeCID = links[i]
    local nodePos = obj:getAbsNodePosition(nodeCID)
    local prevNodePos = obj:getAbsNodePosition(prevNodeCID)

    local col, sizeMult = defaultCol, 1

    if linkColorsSizes then
      local linkColSize = linkColorsSizes[i - 1]
      col = linkColSize.color
      sizeMult = linkColSize.sizeMult
    end

    obj.debugDrawProxy:drawNodeSphere(prevNodeCID, nodeScale * sizeMult, col)
    obj.debugDrawProxy:drawNodeSphere(nodeCID, nodeScale * sizeMult, col)
    obj.debugDrawProxy:drawCylinder(prevNodePos, nodePos, beamScale * sizeMult, col)
    prevNodePos = nodePos
  end

  -- Draw Slidenodes
  for _, slidenode in ipairs(slidenodes) do
    obj.debugDrawProxy:drawNodeSphere(slidenode.id, slideNodeScale, defaultCol)
  end
end

-- find slidenodes attached to this rail by rail's name
local function getSlideNodes(theRailName)
  local slidenodes = {}
  for j = 0, slidenodesCount - 1 do
    local slidenode = v.data.slidenodes[j]
    if slidenode.railName == theRailName then
      tableInsert(slidenodes, slidenode)
    end
  end
  return slidenodes
end

-- Returns list of broken links
local function getBrokenRailLinks(rail)
  local links = rail['links:']
  local brokenLinks = {}
  for i = 1, #links - 1 do
    local beams = railsLinksBeams[rail][i]

    for k, beam in ipairs(beams) do
      if obj:beamIsBroken(beam.cid) then
        brokenLinks[i] = true
      end
    end
  end

  return brokenLinks
end

local function visualizeRailsSlideNodes()
  local partsSelected = M.partsState.partsSelected

  local modeID = M.state.vehicle.railsSlideNodesVisMode
  local mode = M.state.vehicle.railsSlideNodesVisModes[modeID]
  if not mode then return false end

  local modeName = mode.name

  local linkNodeScale = 0.01 * M.state.vehicle.railsSlideNodesVisWidthScale
  local beamScale = math.max(0.01 * M.state.vehicle.railsSlideNodesVisWidthScale - 0.008, 0.00025)
  local slideNodeScale = 0.02 * M.state.vehicle.railsSlideNodesVisWidthScale
  local alpha = M.state.vehicle.railsSlideNodesVisAlpha * 255

  -- "off"
  if modeID == 1 then return end

  -- initialization
  if not railsLinksBeams then
    railsLinksBeams = {}

    -- Find beams between t nodes
    for name, rail in pairs(v.data.rails or {}) do
      if name ~= 'cids' then
        local links = rail['links:']
        railsLinksBeams[rail] = {}

        for i = 2, #links do
          local prevNodeCID = links[i - 1]
          local nodeCID = links[i]

          railsLinksBeams[rail][i - 1] = {}

          -- Find beams between these two nodes
          for j = 0, beamsCount - 1 do
            local beam = v.data.beams[j]

            if (beam.id1 == prevNodeCID and beam.id2 == nodeCID) or (beam.id2 == prevNodeCID and beam.id1 == nodeCID) then
              tableInsert(railsLinksBeams[rail][i - 1], beam)
            end
          end

          prevNodeCID = nodeCID
        end
      end
    end
  end

  if playerInfo.firstPlayerSeated then
    nextLegendColumn()
    drawLegendText(color(255, 165, 0, 255), "Rail Vis Mode: " .. modeName)
  end

  -- "simple"
  if modeID == 2 then
    for name, rail in pairs(v.data.rails or {}) do
      if name ~= 'cids' then
        -- find slidenodes attached to this rail
        local slidenodes = getSlideNodes(name)
        local col = jetColor(rail.cid/(railsCount + 1), alpha)

        drawRailSlidenodes(rail, slidenodes, linkNodeScale, beamScale, slideNodeScale, col)
        --if partSelectedIdx == 1 or partSelected == rail.partPath then end
      end
    end

  -- "withoutBroken", "withBroken", "brokenOnly"
  elseif modeID == 3 or modeID == 4 or modeID == 5 then
    for name, rail in pairs(v.data.rails or {}) do
      if name ~= 'cids' then
        local links = rail['links:']
        local linksNodeCount = #links
        if links and linksNodeCount >= 2 then
          -- find slidenodes attached to this rail
          local slidenodes = getSlideNodes(name)
          local brokenLinks = getBrokenRailLinks(rail)

          if (modeID == 3 and not next(brokenLinks)) or modeID == 4 or (modeID == 5 and next(brokenLinks)) then
            -- non broken ones will have green-blue shade
            local startAngle, endAngle = 90, 240
            local col = jetColor((startAngle + (endAngle - startAngle) * rail.cid / (railsCount + 1)) / 360, alpha)

            -- broken ones will have red-orange shade
            startAngle, endAngle = 0, 45
            local brokenCol = jetColor((startAngle + (endAngle - startAngle) * rail.cid / (railsCount + 1)) / 360, alpha)

            local linkColorsSizes = {}
            for i = 1, linksNodeCount - 1 do
              linkColorsSizes[i] = {color = brokenLinks[i] and brokenCol or col, sizeMult = brokenLinks[i] and 2 or 1}
            end

            drawRailSlidenodes(rail, slidenodes, linkNodeScale, beamScale, slideNodeScale, col, linkColorsSizes)
          end
        end
      end
    end
  end
end

local function updateUIs()
  -- INTENTIONALLY CALLING FROM GAME ENGINE LUA TO WORKAROUND A BUG
  obj:queueGameEngineLua(stringFormat("guihooks.trigger('BdebugUpdate',%s,%s)", serialize(M.state), serialize(M.stateNoReset)))

  -- This is fine though
  obj:queueGameEngineLua(stringFormat("extensions.hook('onBDebugUpdate',%s,%s)", serialize(M.state), serialize(M.stateNoReset)))
end

local function receiveViewportSize(sizeX, sizeY)
  viewportSizeX, viewportSizeY = sizeX, sizeY
end

--local lastTime = 0
local function debugDraw(focusPos)
  -- local currTime = os.clock()
  -- local dt = currTime - lastTime
  -- lastTime = currTime

  local dirty = false
  resetLegendLayout()

  obj:queueGameEngineLua(stringFormatWorkBuffer("if debug_vehicleDebug then debug_vehicleDebug.bdebugRequestViewportSize(%d) end", objectId))

  visualizeWheelThermals()
  visualizeTireContactPoint()
  visualizeSteeringGeometry()
  visualizeCollisionTriangles()
  visualizeAerodynamics()
  visualizeCOG()

  visualizeNodesDebugTexts()
  visualizeNodesTexts()
  dirty = visualizeNodes() or dirty
  visualizeBeamsTexts()
  dirty = visualizeBeams() or dirty
  dirty = visualizeTorsionBars() or dirty
  visualizeRailsSlideNodes()

  if dirty then
    updateUIs()
  end
end

local function updateDebugDraw()
  -- Only enable debugDraw if one of the modes are enabled and M.state.vehicleDebugVisible is true
  M.debugDraw = nop
  for k, v in pairs(M.state.vehicle) do
    if type(v) ~= "table" and v ~= M.initState.vehicle[k] and M.state.vehicleDebugVisible then
      --lastTime = os.clock()
      M.debugDraw = debugDraw
      break
    end
  end

  -- "type + broken" | "brokenOnly"
  if ((M.state.vehicle.beamVisMode == 5 or M.state.vehicle.beamVisMode == 6) and M.state.vehicleDebugVisible) then
    -- Report beams broken before tool was open
    for id = 0, beamsCount - 1 do
      local beam = v.data.beams[id]
      if not beamsBroken[id] and obj:beamIsBroken(id) then
        log("I", "bdebug.beamBroken", stringFormat("beam %d broke: %s [%d]  ->  %s [%d]", id, (v.data.nodes[beam.id1].name or "unnamed"), beam.id1, (v.data.nodes[beam.id2].name or "unnamed"), beam.id2))
        guihooks.message({txt = "vehicle.beamstate.beamBroke", context = {id = id, id1 = beam.id1, id2 = beam.id2, id1name = v.data.nodes[beam.id1].name, id2name = v.data.nodes[beam.id2].name}})
      end
      beamsBroken[id] = true
    end
    M.beamBroke = beamBroke
  else
    M.beamBroke = nop
  end
end

local function updateDebugDrawAndSendState()
  updateDebugDraw()
  updateUIs()
end

-- Request/send drawn nodes to GE Lua function
local function requestDrawnNodesGE(geFuncName)
  requestDrawnNodesCallbacks = requestDrawnNodesCallbacks or {}
  tableInsert(requestDrawnNodesCallbacks, geFuncName)
end

-- Request/send drawn beams to GE Lua function
local function requestDrawnBeamsGE(geFuncName)
  requestDrawnBeamsCallbacks = requestDrawnBeamsCallbacks or {}
  tableInsert(requestDrawnBeamsCallbacks, geFuncName)
end

local function onPlayersChanged(m)
  if m then
    updateDebugDrawAndSendState()
  end
end

local function setState(state, stateNoReset, notSendBack)
  if state.objectId ~= objectId then
    return
  end

  M.state.vehicleDebugVisible = false
  M.state = state
  M.state.vehicle = M.state.vehicle or deepcopy(M.initState.vehicle)
  for k, v in pairs(M.state.vehicle) do
    if type(v) ~= "table" and v ~= M.initState.vehicle[k] then
      M.state.vehicleDebugVisible = true
    end
  end
  M.stateNoReset = stateNoReset

  updateDebugDraw()
  if not notSendBack then
    updateUIs()
  end
end

local function setMode(modeVar, modesVar, mode)
  if M.state.vehicle[modeVar] and M.state.vehicle[modesVar] then
    if mode > #M.state.vehicle[modesVar] then
      mode = 1
    elseif mode < 1 then
      mode = #M.state.vehicle[modesVar]
    end

    M.state.vehicle[modeVar] = mode

    if mode ~= 1 then
      M.state.vehicleDebugVisible = true
    end
  end

  updateDebugDrawAndSendState()
end

local function setPartsSelected(parts)
  M.partsState.partsSelected = parts
end

-- Sets the text to display at a node using the node debug text visualization
-- "type" is the group the text belongs to
-- "nodeCID" is the id of the node at runtime
-- "text" is the text you want to display at the node
local function setNodeDebugText(type, nodeCID, text)
  -- If type doesn't exist, create it!
  if not M.state then return
    log('E', 'bdebugImpl.setNodeDebugText', stringFormat('bdebugImpl.setNodeDebugText(%s, %d, %s) not successful because bdebugImpl.lua is not fully initialized!', type, nodeCID, text))
  end
  local id = M.state.vehicle.nodeDebugTextTypeToID[type]
  if not id then
    tableInsert(M.state.vehicle.nodeDebugTextModes, {name = type, data = {}})
    M.state.vehicle.nodeDebugTextTypeToID[type] = #M.state.vehicle.nodeDebugTextModes
    id = M.state.vehicle.nodeDebugTextTypeToID[type]
  end
  local mode = M.state.vehicle.nodeDebugTextModes[id]

  -- If node data doesn't exist, create it!
  if not mode.data[nodeCID] then
    mode.data[nodeCID] =
    {
      textList = {},
    }
  end

  -- Add text to list
  tableInsert(
    mode.data[nodeCID].textList,
    text
  )

  updateDebugDrawAndSendState()
end

-- Removes the text displaying at a node
-- "type" is the text group
-- "nodeCID" is the id of the node at runtime
local function clearNodeDebugText(type, nodeCID)
  local id = M.state.vehicle.nodeDebugTextTypeToID[type]
  if id then
    M.state.vehicle.nodeDebugTextModes[id].data[nodeCID] = nil
  end
  updateDebugDrawAndSendState()
end

-- Removes a specific text group
-- "type" is the text group
local function clearTypeNodeDebugText(type)
  local id = M.state.vehicle.nodeDebugTextTypeToID[type]
  if id then
    tableRemove(M.state.vehicle.nodeDebugTextModes, id)

    -- Subtract one from mode to keep same mode selected
    if M.state.vehicle.nodeDebugTextMode >= id then
      M.state.vehicle.nodeDebugTextMode = M.state.vehicle.nodeDebugTextMode - 1
    end
    M.state.vehicle.nodeDebugTextTypeToID[type] = nil

    -- Update type to ID lookups as the ids have been shifted down
    for i = id, #M.state.vehicle.nodeDebugTextModes do
      local currType = M.state.vehicle.nodeDebugTextModes[i].name
      M.state.vehicle.nodeDebugTextTypeToID[currType] = M.state.vehicle.nodeDebugTextTypeToID[currType] - 1
    end
  end
  updateDebugDrawAndSendState()
end

-- Removes all text groups
local function clearAllNodeDebugText()
  M.state.vehicle.nodeDebugTextModes = {{name = "off"}}
  M.state.vehicle.nodeDebugTextMode = 1
  tableClear(M.state.vehicle.nodeDebugTextTypeToID)
  updateDebugDrawAndSendState()
end

local function isEnabled()
  return M.state.vehicleDebugVisible
end

local function setEnabled(enabled)
  M.state.vehicleDebugVisible = enabled
  updateDebugDrawAndSendState()
end

-- User input events

-- function used by the input subsystem - AND NOTHING ELSE
-- DO NOT use these from the UI
local function toggleEnabled()
  M.state.vehicleDebugVisible = not M.state.vehicleDebugVisible
  updateDebugDrawAndSendState()
end

local function nodetextModeChange(change)
  setMode("nodeTextMode", "nodeTextModes", M.state.vehicle.nodeTextMode + change)

  local modeName = M.state.vehicle.nodeTextModes[M.state.vehicle.nodeTextMode].name
  guihooks.message({txt = "vehicle.bdebug.nodeTextMode", context = {nodeTextMode = "vehicle.bdebug.nodeTextMode." .. modeName}}, 3, "debug", nil, #M.state.vehicle.nodeTextModes, M.state.vehicle.nodeTextMode-1)
end

local function nodevisModeChange(change)
  setMode("nodeVisMode", "nodeVisModes", M.state.vehicle.nodeVisMode + change)

  local modeName = M.state.vehicle.nodeVisModes[M.state.vehicle.nodeVisMode].name
  guihooks.message({txt = "vehicle.bdebug.nodeVisMode", context = {nodeVisMode = "vehicle.bdebug.nodeVisMode." .. modeName}}, 3, "debug", nil, #M.state.vehicle.nodeVisModes, M.state.vehicle.nodeVisMode-1)
end

local function nodedebugtextModeChange(change)
  setMode("nodeDebugTextMode", "nodeDebugTextModes", M.state.vehicle.nodeDebugTextMode + change)

  local modeName = M.state.vehicle.nodeDebugTextModes[M.state.vehicle.nodeDebugTextMode].name
  guihooks.message({txt = "vehicle.bdebug.nodeDebugTextMode", context = {nodeDebugTextMode = modeName}}, 3, "debug", nil, #M.state.vehicle.nodeDebugTextModes, M.state.vehicle.nodeDebugTextMode-1)
end

local function skeletonModeChange(change)
  setMode("beamVisMode", "beamVisModes", M.state.vehicle.beamVisMode + change)

  local modeName = M.state.vehicle.beamVisModes[M.state.vehicle.beamVisMode].name
  guihooks.message({txt = "vehicle.bdebug.beamVisMode", context = {beamVisMode = "vehicle.bdebug.beamVisMode." .. modeName}}, 3, "debug", nil, #M.state.vehicle.beamVisModes, M.state.vehicle.beamVisMode-1)
end

local function colTrisModeChange(change)
  setMode("collisionTriangleVisMode", "collisionTriangleVisModes", M.state.vehicle.collisionTriangleVisMode + change)

  local modeName = M.state.vehicle.collisionTriangleVisModes[M.state.vehicle.collisionTriangleVisMode].name
  guihooks.message({txt = "vehicle.bdebug.collisionTriangleVisMode", context = {collisionTriangleVisMode = "vehicle.bdebug.collisionTriangleVisMode." .. modeName}}, 3, "debug", nil, #M.state.vehicle.collisionTriangleVisModes, M.state.vehicle.collisionTriangleVisMode-1)
end

local function cogChange(change)
  setMode("cogMode", "cogModes", M.state.vehicle.cogMode + change)

  local modeName = M.state.vehicle.cogModes[M.state.vehicle.cogMode].name
  guihooks.message({txt = "vehicle.bdebug.cogMode", context = {cogMode = "vehicle.bdebug.cogMode." .. modeName}}, 3, "debug", nil, #M.state.vehicle.cogModes, M.state.vehicle.cogMode-1)
end

local function resetModes()
  M.state = deepcopy(M.initState)
  guihooks.message("vehicle.bdebug.clear", 3, "debug")
  updateDebugDrawAndSendState()
end

local function init(savedState, newPartialState)
  log('D', 'bdebugImpl.init', 'init')
  nodesCount = v.data.nodes and tableSizeC(v.data.nodes) or 0
  beamsCount = v.data.beams and tableSizeC(v.data.beams) or 0
  trisCount = v.data.triangles and tableSizeC(v.data.triangles) or 0
  torsionBarsCount = v.data.torsionbars and tableSizeC(v.data.torsionbars) or 0
  railsCount = v.data.rails and tableSize(v.data.rails) or 0
  slidenodesCount = v.data.slidenodes and tableSizeC(v.data.slidenodes) or 0

  railsLinksBeams = nil

  M.state = deepcopy(savedState or M.initState)
  M.state.vehicle.nodeDebugTextTypeToID = newPartialState.vehicle.nodeDebugTextTypeToID
  M.state.vehicle.nodeDebugTextMode = newPartialState.vehicle.nodeDebugTextMode
  M.state.vehicle.nodeDebugTextModes = newPartialState.vehicle.nodeDebugTextModes

  if newPartialState.partsSelected then
    setPartsSelected(newPartialState.partsSelected)
  end

  updateDebugDrawAndSendState()
end

local function reset()
  tableClear(beamsBroken)
  tableClear(beamsDeformed)
  tableClear(deformGroupsTriggerDisplayed)
  tableClear(brokenBreakGroupsDisplayed)
end

M.nodeCollision = nop
M.beamBroke = nop
M.debugDraw = nop

M.receiveViewportSize = receiveViewportSize
M.requestState = updateUIs
M.requestDrawnNodesGE = requestDrawnNodesGE
M.requestDrawnBeamsGE = requestDrawnBeamsGE
M.onPlayersChanged = onPlayersChanged
M.setState = setState
M.setPartsSelected = setPartsSelected
M.setNodeDebugText = setNodeDebugText
M.clearNodeDebugText = clearNodeDebugText
M.clearTypeNodeDebugText = clearTypeNodeDebugText
M.clearAllNodeDebugText = clearAllNodeDebugText

M.isEnabled = isEnabled
M.setEnabled = setEnabled
M.toggleEnabled = toggleEnabled
M.nodetextModeChange = nodetextModeChange
M.nodevisModeChange = nodevisModeChange
M.nodedebugtextModeChange = nodedebugtextModeChange
M.skeletonModeChange = skeletonModeChange
M.colTrisModeChange = colTrisModeChange
M.cogChange = cogChange
M.resetModes = resetModes

M.init = init
M.reset = reset

return M