-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Sphere/handle drawing for the spline-editing tools. Split out of the old monolithic render.lua. Leaf module:
-- depends only on debugDraw + the shared style. getSphereScale is exported because the composite render modules
-- (spline / transport / graph) reuse it for their own distance-scaled spheres.

local M = {}

-- Module dependencies.
local dbgDraw = require('utils/debugDraw')
local styleCore = require('editor/toolUtilities/style')

-- Module constants.
local sin, min = math.sin, math.min
local cullDist = 600.0
local cullDistSq = cullDist * cullDist
local sphereScalePivot = 30.0
local sizeMul = 0.8 -- global handle screen-size trim; lower = smaller handles everywhere.
local maxScreenDist = 60.0 -- constant apparent size out to here; past it the handle keeps its world size and recedes.
local screenSlope = (1.0 / math.sqrt(sphereScalePivot)) * sizeMul -- sizeMul folded in so there's no per-sphere cost.
local style = styleCore.getStyle()


local function getSphereScale(d)
  if d > maxScreenDist then d = maxScreenDist end
  return d * screenSlope
end

local function drawSphereCulled(p, scale, col)
  local camPos = core_camera.getPosition()
  if p:squaredDistance(camPos) < cullDistSq then
    dbgDraw.drawSphere(p, getSphereScale(p:distance(camPos)) * scale, col)
  end
end
local function drawSphereRib(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, dScale * (style.sphereRib + style.ribGlowScale), style.colourRibGlow) -- Glow pass.
  drawSphereCulled(p, style.sphereRib, style.colourRibHandle) -- Core pass.
end
local function drawSphereBar(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, dScale * (style.sphereBar + style.barGlowScale), style.colourBarGlow) -- Glow pass.
  drawSphereCulled(p, style.sphereBar, style.colourBarHandle) -- Core pass.
end
local function drawSphereBarHover(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.sphereBar + style.barGlowScale
  local t = os.clock() * style.highlightHoverPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightHoverScaleMin + (style.highlightHoverScaleMax - style.highlightHoverScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourBarGlow, false)
  drawSphereCulled(p, style.sphereBar, style.colourBarHandle)
end
-- Curve (edge-bend / corner-radius) apex handle, colour-parametrised so each tool can theme it (footprint = green, the hero-road
-- engineered corner knob = its own palette green). Base is a steady dot with a soft glow; hover pulses a larger, brighter glow.
local function drawSphereCurveHandleCol(p, coreCol, glowCol)
  local dScale = getSphereScale(p:distance(core_camera.getPosition()))
  dbgDraw.drawSphere(p, dScale * (style.sphereBar + style.barGlowScale), glowCol)
  drawSphereCulled(p, style.sphereBar, coreCol)
end
local function drawSphereCurveHandleHoverCol(p, coreCol, glowCol)
  local d = p:distance(core_camera.getPosition())
  local baseScale = style.sphereBar + style.barGlowScale
  local t = os.clock() * style.highlightHoverPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightHoverScaleMin + (style.highlightHoverScaleMax - style.highlightHoverScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * 1.6 * k), glowCol, false)
  drawSphereCulled(p, style.sphereBar * 1.15, coreCol)
end
-- Footprint default: green so it stands apart from nodes and cyan bar handles.
local function drawSphereCurveHandle(p) drawSphereCurveHandleCol(p, style.colourCurveHandle, style.colourCurveHandleGlow) end
local function drawSphereCurveHandleHover(p) drawSphereCurveHandleHoverCol(p, style.colourCurveHandle, style.colourCurveHandleGlow) end
local function drawSphereHighlightHover(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.sphereNodeHover
  local t = os.clock() * style.highlightHoverPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightHoverScaleMin + (style.highlightHoverScaleMax - style.highlightHoverScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourHighlightSelected or style.colourHighlight, false)
end

local function drawSphereHighlightHoverFixed(p, radius)
  local t = os.clock() * style.highlightHoverPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightHoverScaleMin + (style.highlightHoverScaleMax - style.highlightHoverScaleMin) * s
  dbgDraw.drawSphere(p, radius * k, style.colourHighlightSelected or style.colourHighlight, false)
end

local function drawSphereHighlightSelected(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.sphereNodeHover
  local t = os.clock() * style.highlightPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightScaleMin + (style.highlightScaleMax - style.highlightScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourHighlight, false)
end

local function drawSphereHighlightSelectedFixed(p, radius)
  local t = os.clock() * style.highlightPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightScaleMin + (style.highlightScaleMax - style.highlightScaleMin) * s
  dbgDraw.drawSphere(p, radius * k, style.colourHighlight, false)
end

local function drawPathNode(p) drawSphereCulled(p, style.sphereNode, style.colourPathNode) end
local function drawSelectedNavGraphNode(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.bigNode
  local t = os.clock() * style.highlightPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightScaleMin + (style.highlightScaleMax - style.highlightScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourPathNodeBig, false)
end
local function drawHoverNavGraphNode(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.sphereNode
  local t = os.clock() * style.highlightHoverPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightHoverScaleMin + (style.highlightHoverScaleMax - style.highlightHoverScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourNodeGlow, false)
end
local function drawSphereNode(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, dScale * (style.sphereNode + style.nodeGlowScale), style.colourNodeGlow) -- Glow pass.
  dbgDraw.drawSphere(p, dScale * style.sphereNode, style.colourNode) -- Core pass.
end
local function drawSphereNodeLocked(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  local s = style.sphereNodeLocked or style.sphereRib
  dbgDraw.drawSphere(p, dScale * (s + style.ribGlowScale), style.colourNodeLockedGlow)
  dbgDraw.drawSphere(p, dScale * s, style.colourNodeLocked)
end
local function drawSphereJunction(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, dScale * (style.sphereNode + style.nodeGlowScale), style.colourJunctionGlow)
  dbgDraw.drawSphere(p, dScale * style.sphereNode, style.colourJunction)
end
local function drawSphereJunctionDull(p)
  drawSphereCulled(p, style.sphereNodeDull, style.colourJunctionDull)
end
local function drawSphereImmediate(p, scale, col) dbgDraw.drawSphere(p, getSphereScale(p:distance(core_camera.getPosition())) * scale, col) end
local function drawSphereCursor(p, isActive)
  local camPos = core_camera.getPosition()
  local col = isActive and style.colourMousePos or style.colourMousePosInactive
  local distance = p:distance(camPos)
  local clampedDistance = min(distance, 100.0) -- Clamp max 100m.
  dbgDraw.drawSphere(p, getSphereScale(clampedDistance) * style.sphereMousePos, col)
end -- Not culled.

local function drawSphereNodeDull(p) drawSphereCulled(p, style.sphereNodeDull, style.colourNodeDull) end
local function drawSphereHighlight(p)
  local camPos = core_camera.getPosition()
  if p:squaredDistance(camPos) < cullDistSq then
    dbgDraw.drawSphere(p, getSphereScale(p:distance(camPos)) * style.sphereNodeHover, style.colourHighlight, false)
  end
end

local function drawSphereNodeForeground(p)
  local camPos = core_camera.getPosition()
  local scale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, scale * (style.sphereNode + style.nodeGlowScale), style.colourNodeGlow, false)
  dbgDraw.drawSphere(p, scale * style.sphereNode, style.colourNode, false)
end

local function drawSphereHighlightForeground(p)
  dbgDraw.drawSphere(p, getSphereScale(p:distance(core_camera.getPosition())) * style.sphereNodeHover, style.colourHighlight, false)
end

-- X-ray ghosts: no depth test, faint, so only the part of a handle buried in terrain or a mesh reads as a ghost.
local function drawSphereNodeGhost(p)
  dbgDraw.drawSphere(p, getSphereScale(p:distance(core_camera.getPosition())) * style.sphereNode, style.colourNodeGhost, false)
end
local function drawSphereJunctionGhost(p)
  dbgDraw.drawSphere(p, getSphereScale(p:distance(core_camera.getPosition())) * style.sphereNode, style.colourJunctionGhost, false)
end
local function drawSphereCornerHandleGhost(p)
  dbgDraw.drawSphere(p, getSphereScale(p:distance(core_camera.getPosition())) * style.sphereBar, style.colourCornerHandleGhost, false)
end
local function drawSphereBarGhost(p)
  dbgDraw.drawSphere(p, getSphereScale(p:distance(core_camera.getPosition())) * style.sphereBar, style.colourBarHandleGhost, false)
end


-- Public interface.
M.getSphereScale = getSphereScale
M.drawSphereCulled = drawSphereCulled
M.drawSphereRib = drawSphereRib
M.drawSphereBar = drawSphereBar
M.drawSphereBarHover = drawSphereBarHover
M.drawSphereHighlightHover = drawSphereHighlightHover
M.drawSphereCurveHandle = drawSphereCurveHandle
M.drawSphereCurveHandleHover = drawSphereCurveHandleHover
M.drawSphereCurveHandleCol = drawSphereCurveHandleCol
M.drawSphereCurveHandleHoverCol = drawSphereCurveHandleHoverCol
M.drawSphereHighlightHoverFixed = drawSphereHighlightHoverFixed
M.drawSphereHighlightSelected = drawSphereHighlightSelected
M.drawSphereHighlightSelectedFixed = drawSphereHighlightSelectedFixed
M.drawPathNode = drawPathNode
M.drawSelectedNavGraphNode = drawSelectedNavGraphNode
M.drawHoverNavGraphNode = drawHoverNavGraphNode
M.drawSphereNode = drawSphereNode
M.drawSphereNodeLocked = drawSphereNodeLocked
M.drawSphereJunction = drawSphereJunction
M.drawSphereJunctionDull = drawSphereJunctionDull
M.drawSphereImmediate = drawSphereImmediate
M.drawSphereCursor = drawSphereCursor
M.drawSphereNodeDull = drawSphereNodeDull
M.drawSphereHighlight = drawSphereHighlight
M.drawSphereNodeForeground = drawSphereNodeForeground
M.drawSphereHighlightForeground = drawSphereHighlightForeground
M.drawSphereNodeGhost = drawSphereNodeGhost
M.drawSphereJunctionGhost = drawSphereJunctionGhost
M.drawSphereCornerHandleGhost = drawSphereCornerHandleGhost
M.drawSphereBarGhost = drawSphereBarGhost

return M