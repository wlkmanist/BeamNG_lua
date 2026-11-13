-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Line drawing for the spline-editing tools. Split out of the old monolithic render.lua. Leaf module: depends on
-- debugDraw, the shared style, and util (blue->red colour ramp). Owns its own tiny scratch pair for the offset
-- wire-frame line.

local M = {}

-- Module dependencies.
local dbgDraw = require('utils/debugDraw')
local styleCore = require('editor/toolUtilities/style')
local util = require('editor/toolUtilities/util')

-- Module constants.
local abs, min, max, floor, sin = math.abs, math.min, math.max, math.floor, math.sin
local cullDist = 600.0
local cullDistSq = cullDist * cullDist
local style = styleCore.getStyle()
local foregroundSplineCol = style.colourSplineForegroundF
local offsetP0, offsetP1 = vec3(), vec3()


local function drawLineImmediate(p0, p1, thickness, col) dbgDraw.drawLineInstance_MinArg(p0, p1, thickness, col) end

local function drawLineCulled(p0, p1, thickness, col)
  local camPos = core_camera.getPosition()
  if p0:squaredDistance(camPos) < cullDistSq and p1:squaredDistance(camPos) < cullDistSq then
    dbgDraw.drawLineInstance_MinArg(p0, p1, thickness, col)
  end
end

local function drawForegroundLine(p0, p1, col)
  debugDrawer:drawLine(p0, p1, col, false)
end

local function drawSplineLineForeground(p0, p1)
  drawForegroundLine(p0, p1, foregroundSplineCol)
end

local function drawWireFrameLine(p0, p1)
  offsetP0:set(p0)
  p0.z = p0.z + 0.05
  offsetP1:set(p1)
  p1.z = p1.z + 0.05
  drawLineCulled(offsetP0, offsetP1, 2, style.colourLayerWire) -- Core pass.
end
local function drawWireFrameLine2(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourLayerWire2)
end
local function drawWireFrameLine3(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourLayerWire3)
end
local function drawPreviewWireLine(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourPreviewWire)
end
local function drawRibLine(p0, p1)
  dbgDraw.drawLineInstance_MinArg(p0, p1, style.ribLineGlowThickness, style.colourRibGlow) -- Glow pass.
  drawLineCulled(p0, p1, style.ribThickness, style.colourRibLine) -- Core pass.
end
local function drawActiveSegLine(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourLayerWire)
end
local function drawGroundLine(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourGround)
end
local function drawGroundLineDull(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourGroundDull)
end
local function drawDropLine(p0, p1, v, lim) drawLineCulled(p0, p1, style.dropThickness, util.getBlueToRedColour(v, 0, lim)) end
local function drawDropLineThick(p0, p1, v, lim) drawLineCulled(p0, p1, style.dropThicknessThicker, util.getBlueToRedColour(v, 0, lim)) end
local function drawDropLineDull(p0, p1) drawLineCulled(p0, p1, style.dropThicknessDull, style.colourDropDull) end
-- Soft elev drop for selected nodes / junction centres (thin, translucent).
local function drawElevDropLine(p0, p1, v, lim)
  local t = max(0, min(1, abs(v) / max(lim or 100, 1e-6)))
  local col = color(floor(70 + t * 160 + 0.5), floor(110 - t * 50 + 0.5), floor(210 - t * 130 + 0.5), 110)
  drawLineCulled(p0, p1, style.dropThickness, col)
end
local function drawSquareCornerLine(p0, p1) drawLineCulled(p0, p1, style.squareCornerThickness, style.colourSquareCorner) end
local function drawSquareCornerLineForeground(p0, p1) drawForegroundLine(p0, p1, style.colourSquareCornerF) end
local function drawNormalLine(p0, p1) drawLineCulled(p0, p1, style.normalThickness, style.colourNormal) end
local function drawRefNormalLine(p0, p1) drawLineCulled(p0, p1, style.normalRefThickness, style.colourRefNormal) end
local function drawNavLine(p0, p1) drawLineCulled(p0, p1, style.splineThickness, style.colourNav) end
local function drawPathLine(p0, p1) drawLineCulled(p0, p1, style.splineThickness, style.colourPath) end
local function drawBarCeilingLine(p0, p1, v, lim) drawLineCulled(p0, p1, style.dropThickness, util.getBlueToRedColour(v, 0, lim)) end
local function drawSplineLineLinked(p0, p1) drawLineCulled(p0, p1, style.splineThickness, style.colourSplineLinked) end
local function drawSplineLineDull(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourSplineDull)
end
local function drawSplineLineUnselected(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourSplineDull)
end
local function drawSplineLine(p0, p1)
  dbgDraw.drawLineInstance_MinArg(p0, p1, 4, style.colourSplineGlow) -- Glow pass.
  dbgDraw.drawLineInstance_MinArg(p0, p1, 2, style.colourSpline) -- Core pass.
end -- Not culled.
local function drawArcSegment(p0, p1) dbgDraw.drawLineInstance_MinArg(p0, p1, style.arcSegThickness, style.colourArcSeg) end -- Not culled.
local function drawJoinLine(p0, p1)
  local t = os.clock() * style.loopPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.loopScaleMin + (style.loopScaleMax - style.loopScaleMin) * s
  dbgDraw.drawLineInstance_MinArg(p0, p1, style.loopThickness * k, style.colourLoop)
end -- Not culled.


-- Public interface.
M.drawLineImmediate = drawLineImmediate
M.drawLineCulled = drawLineCulled
M.drawForegroundLine = drawForegroundLine
M.drawSplineLineForeground = drawSplineLineForeground
M.drawWireFrameLine = drawWireFrameLine
M.drawWireFrameLine2 = drawWireFrameLine2
M.drawWireFrameLine3 = drawWireFrameLine3
M.drawPreviewWireLine = drawPreviewWireLine
M.drawRibLine = drawRibLine
M.drawActiveSegLine = drawActiveSegLine
M.drawGroundLine = drawGroundLine
M.drawGroundLineDull = drawGroundLineDull
M.drawDropLine = drawDropLine
M.drawDropLineThick = drawDropLineThick
M.drawDropLineDull = drawDropLineDull
M.drawElevDropLine = drawElevDropLine
M.drawSquareCornerLine = drawSquareCornerLine
M.drawSquareCornerLineForeground = drawSquareCornerLineForeground
M.drawNormalLine = drawNormalLine
M.drawRefNormalLine = drawRefNormalLine
M.drawNavLine = drawNavLine
M.drawPathLine = drawPathLine
M.drawBarCeilingLine = drawBarCeilingLine
M.drawSplineLineLinked = drawSplineLineLinked
M.drawSplineLineDull = drawSplineLineDull
M.drawSplineLineUnselected = drawSplineLineUnselected
M.drawSplineLine = drawSplineLine
M.drawArcSegment = drawArcSegment
M.drawJoinLine = drawJoinLine

return M