-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This file contains the style settings for various spline-based tools.

local M = {}

-- Module constants.
local im = ui_imgui


-- Gets the UI style properties.
local function getStyle()
  return {
    -- Colours.
    colourMousePos = color(130, 40, 130, 128), -- The colour of the mouse position sphere (cursor).
    colourMousePosInactive = color(255, 0, 0, 110), -- Inactive/disabled state cursor colour (red, transparent).
    colourForestProbe = color(60, 200, 120, 180), -- The colour of the forest probe cursor sphere.
    colourForestFound = color(255, 210, 80, 210), -- The colour of the forest preview items (found forest set).
    colourNode = color(30, 15, 200, 255), -- The colour of the spline node spheres.
    colourNodeLocked = color(255, 40, 40, 255), -- Junction-linked tip (not draggable).
    colourNodeLockedGlow = color(255, 60, 60, 70),
    colourJunction = color(40, 180, 70, 255),
    colourJunctionDull = color(100, 170, 110, 185),
    colourJunctionGlow = color(80, 200, 100, 96),
    colourRibHandle = color(230, 77, 77, 255), -- The colour of the rib handle spheres.
    colourBarHandle = color(25, 178, 178, 255), -- The colour of the bar handle spheres.
    colourHighlight = color(90, 90, 110, 150), -- Darker highlight to read over glowing nodes.
    colourHighlightSelected = color(50, 55, 60, 190), -- Selected-node highlight (darker).

    colourSpline = color(0, 30, 70, 255), -- The colour of the spline line segments when selected.
    colourSplineDull = color(70, 75, 80, 120),
    colourSplineLinked = color(207, 29, 29, 100), -- The colour of the linked spline line segments.
    colourSplineLinkedDull = color(100, 50, 50, 64), -- The colour of the linked spline line segments when not selected.
    colourNodeDull = color(110, 150, 200, 185), -- The colour of the spline node spheres when not selected. (bluer, same transparency)
    colourLayerWire = color(255, 255, 255, 180), -- The colour of the wire frame 1 (eg for layers).
    colourLayerWire2 = color(0, 0, 0, 255), -- The colour of the wire frame 2 (for Master Splines).
    colourLayerWire3 = color(40, 40, 40, 180), -- The colour of the wire frame 3 (for Master Splines).
    colourPreviewWire = color(255, 180, 180, 255), -- The colour of the preview wire frame lines.
    colourRibLine = color(80, 130, 200, 255), -- The colour of the rib lines (the line segment between the two rib handles).
    colourBarLine = color(200, 130, 80, 255), -- The colour of the bar lines (the line segment between the bar and the ground).
    colourGround = color(0, 30, 70, 255), -- The colour of the ground line when selected (for 3D splines).
    colourGroundDull = color(100, 100, 110, 64), -- The colour of the ground line when not selected (for 3D splines).
    colourDrop = color(150, 150, 160, 180), -- The colour of the drop line when selected (for 3D splines).
    colourDropThicker = color(235, 235, 255, 220), -- The colour of thicker drop lines when selected (for 3D splines).
    colourDropDull = color(100, 100, 110, 64), -- The colour of the drop line when not selected (for 3D splines).
    colourNormal = color(180, 180, 180, 100), -- The colour of the normal lines.
    colourRefNormal = color(130, 130, 130, 100), -- The colour of the reference normal lines.
    colourArcSeg = color(255, 255, 0, 100), -- The colour of the arc segments.
    colourLoop = color(230, 77, 77, 255), -- The colour of the candidate loop line, to indicate to user that ends can form a loop.

    colourNotSelectedSurf = color(150, 150, 150, 150), -- The colour of surfaces which are not selected.
    colourNavGraphRibbon = color(80, 130, 200, 80), -- The colour of navgraph ribbon surfaces (more transparent, nicer blue).
    colourNotSelectedSurf2 = color(100, 100, 100, 70), -- The colour of surfaces which are not selected.
    colourPreviewSurf = color(200, 60, 60, 64), -- The colour of preview surfaces.
    colourActiveSurf = color(200, 200, 220, 255), -- The colour of an 'active' surface.

    -- Transport Network bridge / tunnel debug ribbons (amber vs violet).
    colourBridgeSurf = color(230, 160, 50, 200),
    colourBridgeSurfDull = color(180, 120, 40, 120),
    colourBridgeWire = color(255, 190, 70, 255),
    colourBridgeWireDull = color(200, 140, 50, 180),
    colourBridgeNode = color(230, 160, 50, 255),
    colourBridgeNodeDull = color(180, 120, 40, 185),
    colourTunnelSurf = color(120, 80, 200, 200),
    colourTunnelSurfDull = color(80, 55, 140, 120),
    colourTunnelWire = color(160, 110, 255, 255),
    colourTunnelWireDull = color(100, 70, 180, 180),
    colourTunnelNode = color(120, 80, 200, 255),
    colourTunnelNodeDull = color(80, 55, 140, 185),

    -- Subtle glow accents (for selected elements) – low computation, drawn as a single extra pass.
    colourSplineGlow = color(80, 130, 200, 96), -- Outer glow for selected spline lines.
    colourNodeGlow = color(80, 130, 200, 96), -- Outer glow for selected nodes.
    colourRibGlow = color(120, 160, 210, 90),
    colourBarGlow = color(120, 160, 210, 90),
    colourWireGlow = color(200, 200, 220, 110),

    colourGraphClearNode = color(140, 230, 150, 160), -- Colours for the nav graph visualisation.
    colourNavGraphNode = color(100, 120, 100, 200),
    colourPathNode = color(80, 250, 123, 255),
    colourPathNodeBig = color(80, 250, 123, 255),
    colourNav = color(50, 50, 50, 255),
    colourPath = color(152, 255, 152, 255),

    textForeground = color(0, 0, 0, 255), -- The text foreground colour.
    textBackground = color(255, 255, 255, 255), -- The text background colour.

    -- Line thicknesses.
    splineThickness = 7, -- The thickness of the spline line segments when selected.
    splineThicknessDull = 3, -- The thickness of the spline line segments when not selected.
    splineGlowThickness = 11, -- The thickness of the spline glow pass for selected splines.
    wireGlowThickness = 14,
    ribThickness = 4, -- The thickness of the rib lines (slightly thinner so glow reads around it).
    barThickness = 4, -- The thickness of the bar lines.
    wireThickness = 8, -- The thickness of the wire frame.
    wireThickness2 = 12, -- The thickness of the wire frame 2 (for Master Splines).
    wireThickness3 = 4, -- The thickness of the wire frame 3 (for Master Splines).
    activeSegThickness = 10, -- The thickness of the active segment.
    groundThickness = 5, -- The thickness of the ground line when selected (for 3D splines).
    groundThicknessDull = 3, -- The thickness of the ground line when not selected (for 3D splines).
    dropThickness = 2, -- The thickness of the drop line when selected (for 3D splines).
    dropThicknessThicker = 5, -- The thickness of the drop line when selected (for 3D splines).
    dropThicknessDull = 1, -- The thickness of the drop line when not selected (for 3D splines).
    normalThickness = 4, -- The thickness of the normal lines.
    normalRefThickness = 2, -- The thickness of the reference normal lines.
    arcSegThickness = 2, -- The thickness of the arc segments.
    loopThickness = 5, -- The thickness of the loop line.
    layerPolyThickness = 6,
    layerWireThickness = 6,
    ribLineGlowThickness = 12,

    -- Measurement overlays.
    colourMeasurementGuide = color(66, 70, 81, 255),
    colourMeasurementGuideSel = color(21, 24, 32, 255),
    colourMeasurementObstacle = color(255, 0, 0, 180),
    colourExtensionLine = color(0, 0, 0, 255),
    colourExtensionLineSel = color(0, 0, 0, 255),
    measurementGuideThickness = 3,
    measurementGuideThicknessSel = 5,
    measurementObstacleSphereScale = 0.2,
    measurementIntersectionSphereScale = 0.1,

    -- Sphere scale factors.
    sphereMousePos = 0.1, -- The scale factor of the mouse position sphere.
    sphereNode = 0.15, -- The scale factor of the spline node spheres when selected.
    bigNode = 0.3, -- The scale factor of the big graph path node spheres.
    sphereNodeDull = 0.15, -- The scale factor of the spline node spheres when not selected.
    sphereNodeHover = 0.45, -- The scale factor of the spline node sphere highlight (ensure larger than node glow).
    sphereRib = 0.1, -- The scale factor of the rib spheres.
    sphereNodeLocked = 0.1, -- Junction-linked tip — same size as rib handles.
    sphereBar = 0.1, -- The scale factor of the bar spheres.
    nodeGlowScale = 0.18, -- Additional scale for the node glow (added to sphere_node size).
    nodeGlowWidthFactor = 0.00, -- Disabled (width-aware glow removed from hotpath for simplicity).
    ribGlowScale = 0.12, -- Additional scale for the rib glow (added to sphere_rib size).
    barGlowScale = 0.12, -- Additional scale for the bar glow (added to sphere_bar size).

    -- Highlight pulse for selected node (smooth scale modulation).
    highlightPulseHz = 1.2,
    highlightScaleMin = 0.94,
    highlightScaleMax = 1.06,

    -- Hover highlight pulse (subtle and slightly smaller amplitude).
    highlightHoverPulseHz = 1.0,
    highlightHoverScaleMin = 0.96,
    highlightHoverScaleMax = 1.06,

    -- Loop/join pulse (line thickness scale).
    loopPulseHz = 1.1,
    loopScaleMin = 0.92,
    loopScaleMax = 1.08,

    -- Graph big node pulse.
    graphPulseHz = 1.1,
    graphScaleMin = 0.95,
    graphScaleMax = 1.08,
  }
end

-- Blue Rose.
local function getBlueRose()
  return {
    fullWhite = im.ImVec4(0.95, 1.0, 0.95, 0.8),
    dullWhite = im.ImVec4(0.6, 0.8, 0.6, 0.3),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    greenB = im.ImVec4(0.35, 0.75, 0.35, 1.0),
    greenD = im.ImVec4(0.2, 0.45, 0.2, 1.0),
    blueB = im.ImVec4(0.3, 0.6, 0.8, 1.0),
    blueD = im.ImVec4(0.2, 0.4, 0.5, 1.0),
    redB = im.ImVec4(0.6, 0.2, 0.2, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Vapour Static.
local function getVapourStatic()
  return {
    fullWhite = im.ImVec4(1.0, 1.0, 1.0, 0.7),
    dullWhite = im.ImVec4(1.0, 1.0, 1.0, 0.25),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    blueB = im.ImVec4(0.29, 0.62, 0.64, 1.0),
    blueD = im.ImVec4(0.18, 0.36, 0.38, 1.0),
    greenB = im.ImVec4(0.91, 0.45, 0.65, 1.0),
    greenD = im.ImVec4(0.50, 0.23, 0.36, 1.0),
    redB = im.ImVec4(0.76, 0.17, 0.13, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Canyon Clay.
local function getCanyonClay()
  return {
    fullWhite = im.ImVec4(0.98, 0.95, 0.9, 0.7),
    dullWhite = im.ImVec4(0.7, 0.6, 0.5, 0.3),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    greenB = im.ImVec4(0.45, 0.65, 0.4, 1.0),
    greenD = im.ImVec4(0.25, 0.35, 0.2, 1.0),
    blueB = im.ImVec4(0.3, 0.5, 0.6, 1.0),
    blueD = im.ImVec4(0.2, 0.3, 0.4, 1.0),
    redB = im.ImVec4(0.75, 0.35, 0.2, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Terminal Aurora.
local function getTerminalAurora()
  return {
    fullWhite = im.ImVec4(0.9, 0.9, 0.95, 0.7),
    dullWhite = im.ImVec4(0.6, 0.6, 0.65, 0.25),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    blueB = im.ImVec4(0.2, 0.9, 0.75, 1.0),
    blueD = im.ImVec4(0.1, 0.5, 0.4, 1.0),
    greenB = im.ImVec4(0.35, 0.6, 0.3, 1.0),
    greenD = im.ImVec4(0.2, 0.35, 0.2, 1.0),
    redB = im.ImVec4(0.7, 0.25, 0.3, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Summer of Love.
local function getSummerOfLove()
  return {
    fullWhite = im.ImVec4(1, 1, 1, 0.7),
    dullWhite = im.ImVec4(1, 1, 1, 0.25),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    greenB = im.ImVec4(0.93, 0.73, 0.32, 1.0),
    greenD = im.ImVec4(0.53, 0.43, 0.10, 1.0),
    blueB = im.ImVec4(0.91, 0.39, 0.56, 1.0),
    blueD = im.ImVec4(0.55, 0.20, 0.30, 1.0),
    redB = im.ImVec4(0.99, 0.30, 0.00, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Deer Park.
local function getDeerPark()
  return {
    fullWhite = im.ImVec4(1, 1, 1, 0.7),
    dullWhite = im.ImVec4(1, 1, 1, 0.25),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    greenB = im.ImVec4(0.40, 0.75, 0.45, 1.0),
    greenD = im.ImVec4(0.18, 0.35, 0.20, 1.0),
    blueB = im.ImVec4(0.85, 0.75, 0.55, 1.0),
    blueD = im.ImVec4(0.50, 0.45, 0.25, 1.0),
    redB = im.ImVec4(0.65, 0.35, 0.20, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Dream Machine.
local function getDreamMachine()
  return {
    fullWhite = im.ImVec4(1.0, 1.0, 1.0, 0.7),
    dullWhite = im.ImVec4(0.65, 0.65, 0.65, 0.25),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    blueB = im.ImVec4(0.9, 0.6, 0.85, 1.0),
    blueD = im.ImVec4(0.4, 0.3, 0.5, 1.0),
    greenB = im.ImVec4(0.55, 0.85, 0.75, 1.0),
    greenD = im.ImVec4(0.25, 0.5, 0.45, 1.0),
    redB = im.ImVec4(1.0, 0.5, 0.5, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Headlights.
local function getHeadlights()
  return {
    fullWhite = im.ImVec4(1, 1, 1, 0.7),
    dullWhite = im.ImVec4(1, 1, 1, 0.25),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    greenB = im.ImVec4(0.90, 0.90, 0.90, 1.0),
    greenD = im.ImVec4(0.50, 0.50, 0.50, 1.0),
    blueB = im.ImVec4(1.0, 1.0, 0.55, 1.0),
    blueD = im.ImVec4(0.60, 0.60, 0.20, 1.0),
    redB = im.ImVec4(1.0, 0.35, 0.35, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Crystal.
local function getCrystal()
  return {
    fullWhite = im.ImVec4(0.95, 0.95, 1.0, 0.7),
    dullWhite = im.ImVec4(0.6, 0.6, 0.7, 0.7),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    blueB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    blueD = im.ImVec4(0.25, 0.35, 0.45, 1.0),
    greenB = im.ImVec4(0.9, 0.9, 0.4, 1.0),
    greenD = im.ImVec4(0.4, 0.4, 0.2, 1.0),
    redB = im.ImVec4(1.0, 0.4, 0.5, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Neo-Industrial.
local function getNeoIndustrial()
  return {
    fullWhite = im.ImVec4(0.95, 0.95, 0.95, 0.75),
    dullWhite = im.ImVec4(0.95, 0.95, 0.95, 0.2),
    purpleB = im.ImVec4(0.6, 0.8, 1.0, 1.0),
    greenB = im.ImVec4(0.4, 0.75, 0.5, 1.0),
    greenD = im.ImVec4(0.2, 0.4, 0.25, 1.0),
    blueB = im.ImVec4(0.35, 0.6, 0.9, 1.0),
    blueD = im.ImVec4(0.15, 0.3, 0.6, 1.0),
    redB = im.ImVec4(0.9, 0.3, 0.3, 1.0),
    yellowB = im.ImVec4(0.4, 1.0, 0.4, 1.0),
  }
end

-- Return the imgui colour palette for the given theme.
local function getImguiCols(theme)
  if theme == "blueRose" then
    return getBlueRose()
  elseif theme == "vapourStatic" then
    return getVapourStatic()
  elseif theme == "canyonClay" then
    return getCanyonClay()
  elseif theme == "terminalAurora" then
    return getTerminalAurora()
  elseif theme == "summerOfLove" then
    return getSummerOfLove()
  elseif theme == "deerPark" then
    return getDeerPark()
  elseif theme == "dreamMachine" then
    return getDreamMachine()
  elseif theme == "headlights" then
    return getHeadlights()
  elseif theme == "crystal" then
    return getCrystal()
  elseif theme == "neoIndustrial" then
    return getNeoIndustrial()
  end
  return getCrystal() -- Default theme.
end


-- Public interface.
M.getStyle =                                            getStyle
M.getImguiCols =                                        getImguiCols

return M