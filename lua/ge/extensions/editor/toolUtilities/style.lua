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
    colourLanePick = color(230, 77, 77, 90), -- Fill over the lanes a dragged road end would join.
    colourLaneSweepOk = color(150, 200, 255, 70), -- Fill over the road a lane sweep would split off.
    colourPortalLeave = color(40, 180, 70, 70), -- Open lane portal where traffic leaves the road.
    colourPortalLeaveLit = color(70, 235, 110, 170),
    colourPortalEnter = color(220, 50, 50, 70), -- Open lane portal where traffic enters the road.
    colourPortalEnterLit = color(255, 95, 95, 170),
    colourPortalEdgeF = ColorF(1.0, 1.0, 1.0, 0.86), -- Outline of lit portals and of a valid sweep's road.
    colourLanePickEdgeF = ColorF(0.9, 0.3, 0.3, 1.0), -- Outline of picked lanes and of a refused sweep's road.

    colourNotSelectedSurf = color(150, 150, 150, 150), -- The colour of surfaces which are not selected.
    colourNavGraphRibbon = color(80, 130, 200, 80), -- The colour of navgraph ribbon surfaces (more transparent, nicer blue).
    colourNotSelectedSurf2 = color(100, 100, 100, 70), -- The colour of surfaces which are not selected.
    colourPreviewSurf = color(200, 60, 60, 64), -- The colour of preview surfaces.
    colourActiveSurf = color(200, 200, 220, 255), -- The colour of an 'active' surface.

    -- Some of these draw through debugDrawer:drawLine / :drawSphere, which take a ColorF (not the packed color() used
    -- elsewhere); the direction arrows draw as packed solid tris. Kept here so the tools have no hardcoded colours.
    colourDirectionArrow = color(60, 255, 130, 230), -- lane / track direction-of-travel arrows on links
    colourDirectionArrowGhost = color(60, 255, 130, 90), -- their faint no-depth copy, so arrows on buried links still show
    colourDirectionArrowBack = color(70, 160, 255, 230), -- lanes running against the link's node order (finish -> start)
    colourDirectionArrowBackGhost = color(70, 160, 255, 90),
    colourSplineForegroundF = ColorF(0.31, 0.51, 0.78, 1.0), -- foreground spline line (debugDrawer:drawLine, ColorF)
    colourCrossingGhostF = ColorF(0.25, 0.9, 0.45, 1.0), -- crossing-stitch ghost preview lines
    -- X-ray ghost of the road ribbons and selected handles, drawn without depth test: invisible where the real pass shows, faint where it is buried.
    colourRibbonGhostF = ColorF(0.0, 0.0, 0.0, 0.55),
    colourNodeGhost = color(30, 15, 200, 160),
    colourJunctionGhost = color(40, 180, 70, 160),
    colourCornerHandleGhost = color(30, 140, 100, 160),
    colourBarHandleGhost = color(25, 178, 178, 160),

    -- Engineered-geometry overlay (shared engineeredGeom.drawControlPolygon + the hero-road corner handles). One coherent family:
    -- a desaturated blue-GREY construction guide that recedes, a teal->amber curvature-coloured driven centerline (cool = straight,
    -- warm = tightest bend), indigo corner dots, and violet helper/tether lines -- deliberately OFF the saturated blue used for the
    -- selected spline line (colourSplineForegroundF) so the raw-node guide never reads as the road. All ColorF (debugDrawer:drawLine).
    colourEngGuideF = ColorF(0.42, 0.48, 0.58, 0.65),      -- PI construction polygon (raw node polyline the road rounds): desaturated steel grey-blue that recedes.
    colourEngGuideNodeF = ColorF(0.42, 0.46, 0.82, 0.90),  -- dot on each interior corner PI: indigo (ties to the blue node family).
    colourEngCenterCoolF = ColorF(0.50, 0.66, 0.80, 0.90), -- driven centerline at ZERO curvature (straight): pale steel-blue (soft, not paint-like).
    colourEngCenterHotF = ColorF(0.95, 0.62, 0.22, 0.90),  -- driven centerline at the tightest bend: warm amber highlight.
    colourEngHelperF = ColorF(0.60, 0.50, 0.85, 1.0),      -- corner-handle tether / connector lines: soft violet (an indigo-family accent).

    -- Massing Editor overlays. On-scheme with the shared display palette above: blue/grey base, yellow as the one hot
    -- accent (the active selection), red for the grab handle (like the spline rib handles), purple for the selected solid.
    -- Packed color() like the surface colours above; kept here so the tool has no hardcoded colours.
    colourMassingFootprintFill = color(70, 140, 220, 55),  -- flat resolved 2D footprint fill (footprint step, blue base).
    colourMassingCellGrid = color(95, 125, 170, 140),      -- bay x storey cell grid on the walls (muted steel blue-grey, subtle scaffolding).
    colourMassingCellHover = color(235, 240, 250, 55),     -- hovered cell fill (soft white).
    colourMassingCellHoverEdge = color(215, 228, 248, 210),
    colourMassingDrag = color(255, 232, 60, 80),           -- live drag-rectangle fill (yellow: the active selection being painted).
    colourMassingPullFill = color(255, 232, 60, 70),       -- merged pull-ready face fill (yellow, matching the drag).
    colourMassingPullEdge = color(255, 240, 0, 255),       -- merged pull-ready face outline (bright yellow accent).
    colourMassingHandle = color(232, 84, 84, 255),         -- pull handle core (red grab knob, matches the spline rib handles).
    colourMassingHandleGlow = color(232, 84, 84, 120),     -- pull handle glow (red), pulses on hover.
    colourMassingSelectedPrism = color(60, 220, 120, 255), -- selected solid's prism outline (vivid green; pops against the blue grid, yellow selection and red handle).
    colourMassingEditGhostAdd = color(90, 210, 120, 200),  -- footprint-step ghost of a massing pull that ADDS area (green dashed outline; distinct from the deep-blue footprint polygon).
    colourMassingEditGhostCut = color(225, 85, 85, 200),   -- footprint-step ghost of a push-IN pull (red dashed outline; reads as carved-away rather than added).
    colourMassingEditSelected = color(255, 240, 0, 110),   -- footprint-step outline of the extrusion selected in the list (yellow, thick but translucent so its dashed ghost still reads through it).
    colourMassingPivot = color(235, 40, 40, 255),          -- fixed pivot / origin node (red), the export origin.
    colourMassingAreaPlan = color(185, 125, 255, 230),      -- footprint-step outline of a basement area's trench (violet: ground that is dug away rather than built on, so paving stops at it).
    colourMassingGroundBuilt = color(255, 175, 90, 220),    -- footprint-step outline of what already stands on the ground: ground-level decks and the flights that land on soil (amber, so paving is drawn around them).
    colourMassingGroundGate = color(80, 235, 130, 235),     -- footprint-step tick across a gate at ground level (green: the way in, where a path is meant to arrive).
    colourMassingGroundPlant = color(120, 190, 110, 200),   -- footprint-step mark at the foot of each ground-level plant (leaf green, duller than the gates so a sown garden doesn't shout).
    massingPulseHz = 0.8,                                  -- selection pulse rate (slow brightness breathe shared by the prism and the pull-ready face).
    massingOverlayThickness = 4.0,                         -- hover / drag / selection edge thickness (bold so the selection stands out over the grid).
    massingGridThickness = 2.25,                           -- cell grid lines (thinner than the selection edges).
    massingPullThickness = 5.0,                            -- pull-ready face outline (boldest so the active face reads clearly).

    -- City Builder overlays.
    colourPlacerBoxHover = color(130, 180, 240, 255),      -- box round the building under the cursor (light blue, quiet).
    colourPlacerBoxHoverGlow = color(40, 70, 120, 255),    -- its wide backing pass.
    colourPlacerBoxGlow = color(30, 70, 140, 255),         -- wide backing pass under the selected box (deep blue).
    colourPlacerBoxGhost = color(120, 245, 165, 255),      -- box of the building about to be dropped (green: nothing there yet).
    colourPlacerBoxGhostGlow = color(20, 60, 40, 255),     -- its backing pass, so the green reads over pale ground too.
    colourPlacerBoxBlocked = color(245, 105, 105, 255),    -- the same box standing on a road (red: it cannot be dropped here).
    colourPlacerBoxBlockedGlow = color(70, 18, 18, 255),   -- its backing pass.
    placerBoxThickness = 4.0,                              -- selected box edge width, before the selection pulse widens it.
    placerHoverThickness = 2.5,                            -- hover box edge width (thinner, so the selection always wins).
    placerGhostThickness = 2.0,                            -- cursor box edge width (thinnest of the three).
    placerGlowMul = 2.8,                                   -- how much wider the backing pass is than the edge it sits under.

    -- The draughtsman's square-corner mark, drawn inside a footprint corner that turns a true right angle.
    colourSquareCorner = color(235, 40, 40, 255),           -- red, as the convention is on a drawing. Not a selection state.
    colourSquareCornerF = ColorF(0.92, 0.16, 0.16, 1.0),    -- the same red for the foreground pass (debugDrawer:drawLine, ColorF).
    squareCornerThickness = 2.5,

    -- Subtle glow accents (for selected elements) – low computation, drawn as a single extra pass.
    colourSplineGlow = color(80, 130, 200, 96), -- Outer glow for selected spline lines.
    colourNodeGlow = color(80, 130, 200, 96), -- Outer glow for selected nodes.
    colourRibGlow = color(120, 160, 210, 90),
    colourBarGlow = color(120, 160, 210, 90),
    colourCurveHandle = color(70, 205, 95, 255),      -- footprint edge curve (bend) apex handle - green, distinct from cyan bar handles / blue nodes.
    colourCurveHandleGlow = color(150, 155, 165, 170), -- its hover/base glow - grey so the green core reads clearly against it.
    colourEngHandle = color(12, 92, 66, 255),          -- hero-road engineered corner-radius knob: dark cold forest green - reads apart from the royal-blue node.
    colourEngHandleGlow = color(45, 120, 92, 150),     -- its hover/base glow - muted dark cold green so the core stays legible.
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
    bigNode = 0.24, -- The scale factor of the big graph path node spheres.
    sphereNodeDull = 0.15, -- The scale factor of the spline node spheres when not selected.
    sphereNodeHover = 0.30, -- The scale factor of the spline node sphere highlight (ensure larger than node glow). Kept tight so hovered/selected nodes read as a crisp handle instead of a screen-filling blob.
    sphereRib = 0.1, -- The scale factor of the rib spheres.
    sphereNodeLocked = 0.1, -- Junction-linked tip — same size as rib handles.
    sphereBar = 0.1, -- The scale factor of the bar spheres.
    nodeGlowScale = 0.12, -- Additional scale for the node glow (added to sphere_node size).
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