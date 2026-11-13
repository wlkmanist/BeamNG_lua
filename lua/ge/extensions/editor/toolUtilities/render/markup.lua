-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Text markup drawing for the spline-editing tools. Owns the culled text-draw primitives plus every canned label helper.
-- Leaf module: only depends on debugDraw + the shared style.

local M = {}

-- Module dependencies.
local dbgDraw = require('utils/debugDraw')
local styleCore = require('editor/toolUtilities/style')

-- Module constants.
local deg = math.deg
local style = styleCore.getStyle()


-- Labels that repeat (names, lengths, per-node values) cull at a shorter distance (250 m; 250*250 squared) than
-- geometry, so a zoomed-out view doesn't flood. Cursor prompts are only ever one at a time and draw unculled, so they
-- still read from high above while planning.
local function drawMarkupCulled(pos, text)
  if pos:squaredDistance(core_camera.getPosition()) < 62500 then
    dbgDraw.drawTextAdvanced(pos, text, style.textForeground, true, false, style.textBackground, false, false)
  end
end
local function drawMarkupCulledAlwaysShow(pos, text)
  if pos:squaredDistance(core_camera.getPosition()) < 62500 then
    dbgDraw.drawTextAdvanced(pos, text, style.textForeground, true, false, style.textBackground, false, false)
  end
end
-- Drawn WITHOUT the distance cull, for the one or two labels that must stay readable however far the camera pulls back.
local function drawMarkupUnculled(pos, text)
  dbgDraw.drawTextAdvanced(pos, text, style.textForeground, true, false, style.textBackground, false, false)
end
local function drawMarkupCulledInvertedCols(pos, text)
  if pos:squaredDistance(core_camera.getPosition()) < 62500 then
    dbgDraw.drawTextAdvanced(pos, text, style.textBackground, true, false, style.textForeground, false, false)
  end
end

local function markupText(pos, text) drawMarkupCulled(pos, text) end
local function markupPrompt(pos, text) drawMarkupUnculled(pos, text) end
local function markupLines(pos, lines)
  if not lines or #lines == 0 then return end
  drawMarkupCulled(pos, table.concat(lines, "\n"))
end
local function markupStack(pos, lines)
  if not lines or #lines == 0 then return end
  for i = 1, #lines do
    drawMarkupCulled(pos, lines[i])
  end
end
local function markupDrag(pos) drawMarkupUnculled(pos, '[Click To Select, Drag To Move]') end
local function markupLinkedTip(pos) drawMarkupUnculled(pos, '[Linked — Drag Away Or Use Detach Button]') end
local function markupSelectSpline(pos) drawMarkupUnculled(pos, '[Click To Select Spline]') end
local function markupSelectedSplineDisabled(pos) drawMarkupUnculled(pos, '[Spline Disabled. Cannot Edit]') end
local function markupSelectOrAdd(pos) drawMarkupUnculled(pos, "[Select A Spline Or Click 'Add']") end
local function markupAddNode(pos) drawMarkupUnculled(pos, '[Click To Add Node]') end
local function markupInsertNode(pos) drawMarkupUnculled(pos, '[Click To Insert Node]') end
local function markupRoadLength(pos, l) drawMarkupCulledInvertedCols(pos, string.format('[Length = %.2f m]', l)) end
local function markupAdjustWidth(pos) drawMarkupUnculled(pos, '[Drag To Adjust Width. Hold SHIFT For Precision]') end
local function markupAdjustBar(pos) drawMarkupUnculled(pos, '[Drag To Adjust Height. Hold SHIFT For Precision]') end
local function markupAdjustDepth(pos) drawMarkupUnculled(pos, '[Drag To Adjust Depth. Hold SHIFT For Precision]') end
local function markupWidthDisplay(pos, w) drawMarkupUnculled(pos, string.format('[Width = %.2f m]', w)) end
local function markupDepthDisplay(pos, d) drawMarkupUnculled(pos, string.format('[d = %.2f m]', d)) end
local function markupAddPolygonNode(pos) drawMarkupUnculled(pos, '[Click To Add Node. Double-Click To Finish]') end
local function markupStart(pos) drawMarkupCulledInvertedCols(pos, '[Start]') end
local function markupEnd(pos) drawMarkupCulledInvertedCols(pos, '[End]') end
local function markupAddPairLeft(pos) drawMarkupUnculled(pos, '[Add Pair: Click 1st Node]') end
local function markupPairFirstNode(pos) drawMarkupUnculled(pos, '[Pair: First Node]') end
local function markupPairSecondNode(pos) drawMarkupUnculled(pos, '[Left Click: Add 2nd Node. Right Click: Cancel Pair]') end
local function markupNode1(pos) drawMarkupCulled(pos, 'Node [1]') end
local function markupNode2(pos) drawMarkupCulled(pos, 'Node [2]') end
local function markupNode3(pos) drawMarkupCulled(pos, 'Node [3]') end
local function markupSplineName(pos, str) drawMarkupCulled(pos, string.format('[%s]', str)) end
-- The same label for the one thing being worked on, which stays legible from any distance.
local function markupSelectedName(pos, str) drawMarkupUnculled(pos, string.format('[%s]', str)) end
local function markupActiveSurf(pos) drawMarkupCulled(pos, '[Active Surface (2D)]') end
local function markupVolume(pos) drawMarkupCulled(pos, '[Active Volume (3D)]') end
-- Elevation is drawn WITHOUT the distance cull (there's only ever one, on the selected node) so it stays readable when zoomed out.
local function markupElevation(pos, elev) dbgDraw.drawTextAdvanced(pos, string.format('[Elevation = %.2f m]', elev), style.textForeground, true, false, style.textBackground, false, false) end
local function markupTwistAngle(pos, angleDeg) drawMarkupCulled(pos, string.format('[Twist Angle = %.2f deg]', angleDeg)) end
local function markupVelocity(pos, vel, isBarsLimit, unitsStr)drawMarkupCulled(pos, string.format('[%s = %.2f %s]', isBarsLimit and 'Limit' or 'Velocity', vel, unitsStr)) end
local function markupGraphNodeHover(pos) drawMarkupUnculled(pos, '[Click To Add/Remove From Path]') end
local function markupGraphFreeSpace(pos) drawMarkupUnculled(pos, '[Click NavGraph Node To Add To Path]') end
local function markupPathNode(pos, i) drawMarkupCulled(pos, string.format('Path Node [%d]', i)) end
-- The whole masterSpline suite gates joins/loops on CTRL (see splineInput): the preview shows whenever a candidate
-- exists, and the release only commits while CTRL is held.
local function markupLoop(pos) drawMarkupUnculled(pos, '[Hold CTRL + Drop To Form Loop]') end
local function markupJoin(pos) drawMarkupUnculled(pos, '[Hold CTRL + Drop To Join]') end
local function markupLinkedSplineCannotAdd(pos) drawMarkupUnculled(pos, '[Linked Spline - Cannot Add Nodes]') end
local function markupLoopedSplineCannotAdd(pos) drawMarkupUnculled(pos, '[Looped Spline - Cannot Add Here]') end
local function markupObstacleDistance(pos, dist) drawMarkupCulledAlwaysShow(pos, string.format('[Obstacle: %.1f m]', dist)) end
local function markupObstacleDistanceWithElevation(pos, dist, elevDiff) drawMarkupCulledAlwaysShow(pos, string.format('[Obstacle: %.1f m; dZ = %.1fm]', dist, elevDiff)) end
local function markupAngleAndDistance(pos, dist, angleRad) drawMarkupCulledAlwaysShow(pos, string.format('%.1f m; %.1f°', dist, deg(angleRad))) end
local function markupAngleDistanceWithElevation(pos, dist, angleRad, elevDiff) drawMarkupCulledAlwaysShow(pos, string.format('%.1f m; %.1f°; dZ = %.1fm', dist, deg(angleRad), elevDiff)) end


-- Public interface.
M.drawMarkupCulled = drawMarkupCulled
M.drawMarkupUnculled = drawMarkupUnculled
M.drawMarkupCulledAlwaysShow = drawMarkupCulledAlwaysShow
M.drawMarkupCulledInvertedCols = drawMarkupCulledInvertedCols
M.markupText = markupText
M.markupPrompt = markupPrompt
M.markupLines = markupLines
M.markupStack = markupStack
M.markupDrag = markupDrag
M.markupLinkedTip = markupLinkedTip
M.markupSelectSpline = markupSelectSpline
M.markupSelectedSplineDisabled = markupSelectedSplineDisabled
M.markupSelectOrAdd = markupSelectOrAdd
M.markupAddNode = markupAddNode
M.markupInsertNode = markupInsertNode
M.markupRoadLength = markupRoadLength
M.markupAdjustWidth = markupAdjustWidth
M.markupAdjustBar = markupAdjustBar
M.markupAdjustDepth = markupAdjustDepth
M.markupWidthDisplay = markupWidthDisplay
M.markupDepthDisplay = markupDepthDisplay
M.markupAddPolygonNode = markupAddPolygonNode
M.markupStart = markupStart
M.markupEnd = markupEnd
M.markupAddPairLeft = markupAddPairLeft
M.markupPairFirstNode = markupPairFirstNode
M.markupPairSecondNode = markupPairSecondNode
M.markupNode1 = markupNode1
M.markupNode2 = markupNode2
M.markupNode3 = markupNode3
M.markupSplineName = markupSplineName
M.markupSelectedName = markupSelectedName
M.markupActiveSurf = markupActiveSurf
M.markupVolume = markupVolume
M.markupElevation = markupElevation
M.markupTwistAngle = markupTwistAngle
M.markupVelocity = markupVelocity
M.markupGraphNodeHover = markupGraphNodeHover
M.markupGraphFreeSpace = markupGraphFreeSpace
M.markupPathNode = markupPathNode
M.markupLoop = markupLoop
M.markupJoin = markupJoin
M.markupLinkedSplineCannotAdd = markupLinkedSplineCannotAdd
M.markupLoopedSplineCannotAdd = markupLoopedSplineCannotAdd
M.markupObstacleDistance = markupObstacleDistance
M.markupObstacleDistanceWithElevation = markupObstacleDistanceWithElevation
M.markupAngleAndDistance = markupAngleAndDistance
M.markupAngleDistanceWithElevation = markupAngleDistanceWithElevation

return M