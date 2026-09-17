-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared, read-only debug visualization for crawl paths, segments, boundaries and
-- starting positions. Used by both the crawl editor (always-draw overlays) and the
-- runtime dev overlay so the two stay visually consistent.

local M = {}

-- Colors are kept consistent with the live gate marker modes for easy correlation.
local colNormal   = ColorF(1.0, 1.0, 1.0, 0.5)
local colRecovery = ColorF(1.0, 0.85, 0.0, 0.7)
local colBonus    = ColorF(0.8, 0.2, 1.0, 0.7)
local colFinal    = ColorF(0.1, 0.3, 1.0, 0.8)
local colArrow    = ColorF(0.0, 1.0, 0.0, 0.85)
local colSegment  = ColorF(0.2, 0.7, 1.0, 0.6)
local colLabelBg  = ColorI(0, 0, 0, 192)
local colLabelFg  = ColorF(1, 1, 1, 1)
local colDistFg   = ColorF(0.7, 0.9, 1.0, 1.0)
local colDistBg   = ColorI(0, 0, 0, 150)
local colStart    = ColorF(0.2, 1.0, 0.4, 0.35)
local colIcon     = ColorF(0.2, 0.8, 1.0, 0.6)

local arrowTail = Point2F(0.4, 0.4)
local arrowTip  = Point2F(0.0, 0.1)

local function nodeColor(node, isFinal)
  local flags = node.flags
  if flags then
    if flags.isRecoveryCheckpoint then return colRecovery end
    if flags.isBonusCheckpoint then return colBonus end
  end
  if isFinal then return colFinal end
  return colNormal
end

local function nodeLabel(node, index)
  local label = tostring(index)
  if node.name and node.name ~= "" then
    label = index .. ": " .. node.name
  end
  local flags = node.flags
  if flags then
    if flags.isRecoveryCheckpoint then label = label .. " [REC]" end
    if flags.isBonusCheckpoint then label = label .. " [BONUS]" end
  end
  return label
end

-- Draws waypoints (spheres + facing arrows + labels) and the segments between them.
-- opts: { maxDist = number, showSegmentDistance = bool, showLabels = bool }
function M.drawPath(nodes, opts)
  if not nodes or #nodes == 0 then return end
  opts = opts or {}
  local maxDist = opts.maxDist or 400
  local maxDistSq = maxDist * maxDist
  local showLabels = opts.showLabels ~= false
  local camPos = core_camera.getPosition()
  local n = #nodes

  for i = 1, n do
    local node = nodes[i]
    local pos = node.pos
    if pos and camPos:squaredDistance(pos) <= maxDistSq then
      local isFinal = (i == n)
      debugDrawer:drawSphere(pos, node.radius or 4.0, nodeColor(node, isFinal))

      if node.rotation then
        local fwd = node.rotation * vec3(0, 1, 0)
        debugDrawer:drawSquarePrism(pos, pos + fwd * 3.0, arrowTail, arrowTip, colArrow)
      end

      if showLabels then
        debugDrawer:drawTextAdvanced(pos, String(nodeLabel(node, i)), colLabelFg, true, false, colLabelBg)
      end
    end
  end

  local cumDist = 0
  for i = 1, n - 1 do
    local a = nodes[i].pos
    local b = nodes[i + 1].pos
    if a and b then
      local segLen = a:distance(b)
      cumDist = cumDist + segLen
      local mid = (a + b) * 0.5
      if camPos:squaredDistance(mid) <= maxDistSq then
        debugDrawer:drawCylinder(a, b, 0.15, colSegment)
        if opts.showSegmentDistance then
          debugDrawer:drawTextAdvanced(mid, String(string.format("%.0f m", cumDist)), colDistFg, true, false, colDistBg)
        end
      end
    end
  end
end

-- Draws the boundary zone (fence + planes). zone:drawDebug already does camera culling.
function M.drawBoundary(boundary, drawMode)
  if not boundary or not boundary.drawDebug then return end
  boundary:drawDebug(drawMode)
end

-- Draws the starting position area sphere, icon marker and facing arrow.
function M.drawStartingPosition(startingPosition)
  if not startingPosition or not startingPosition.transform then return end
  local t = startingPosition.transform
  if t.position then
    debugDrawer:drawSphere(t.position, t.radius or 10.0, colStart)
    if t.rotation then
      local fwd = t.rotation * vec3(0, 1, 0)
      debugDrawer:drawSquarePrism(t.position, t.position + fwd * 4.0, arrowTail, arrowTip, colArrow)
    end
  end
  if startingPosition.iconPosition then
    debugDrawer:drawSphere(startingPosition.iconPosition, 0.5, colIcon)
  end
end

return M
