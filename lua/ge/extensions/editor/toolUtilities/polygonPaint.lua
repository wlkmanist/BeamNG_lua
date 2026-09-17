-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Freehand polygon paint utility:
-- - click/hold LMB and drag to place points on the terrain
-- - release LMB to finish (closure is implied by last->first)
-- - simplifies using RDP for a clean editable polygon

local M = {}

local im = ui_imgui

local render = require('editor/toolUtilities/render')
local util = require('editor/toolUtilities/util')
local rdp = require('editor/toolUtilities/rdp')
local style = require('editor/toolUtilities/style')

-- Defaults tuned for quick paint then edit.
local defaultStepMeters = 2.0      -- min distance between captured points
local defaultRdpTolMeters = 6.0    -- RDP tolerance (meters)

-- Packed integer colours (debugDraw expects packed ints via `color()`).
local previewCol = color(70, 160, 255, 255)      -- blue-ish (distinct from cursor)
local previewColEdge = color(70, 160, 255, 180)  -- softer blue edge

-- State.
local active = false
local drawing = false
local finished = false
local points = {}
local simplified = {}
local lastP = vec3()

local stepSq = defaultStepMeters * defaultStepMeters
local rdpTol = defaultRdpTolMeters

local cursorPos = vec3()

local toolStyle = style.getStyle()
local paintSphereScale = toolStyle.sphereMousePos

local function clearTables()
  table.clear(points)
  table.clear(simplified)
  finished = false
end

local function start(opts)
  opts = opts or {}
  stepSq = (opts.stepMeters or defaultStepMeters)
  stepSq = stepSq * stepSq
  rdpTol = opts.rdpTolMeters or defaultRdpTolMeters

  clearTables()
  active = true
  drawing = false
end

local function cancel()
  active = false
  drawing = false
  clearTables()
end

local function isActive()
  return active
end

local function hasFinished()
  return finished
end

local function consumePolygon(out)
  if not finished then
    return nil
  end
  finished = false
  local ret = out or {}
  table.clear(ret)
  for i = 1, #simplified do
    ret[i] = simplified[i]
  end
  return ret
end

local function addPoint(p)
  -- Copy + lift slightly above terrain to avoid z-fighting.
  local v = vec3(p)
  v.z = core_terrain.getTerrainHeight(v) + 0.05
  points[#points + 1] = v
  lastP:set(v)
end

local function simplifyPolyline()
  table.clear(simplified)
  if #points < 3 then
    return false
  end
  for i = 1, #points do
    simplified[i] = points[i]
  end
  rdp.simplifyNodes(simplified, rdpTol)
  return #simplified >= 3
end

local function renderPreview()
  local n = #points
  if n < 1 then
    return
  end

  for i = 1, n do
    -- Use the same render helper style as other tools; make spheres clearly visible.
    render.drawSphereImmediate(points[i], paintSphereScale, previewCol)
    if i > 1 then
      render.drawLineImmediate(points[i - 1], points[i], 2, previewColEdge)
    end
  end
  if n > 2 then
    render.drawLineImmediate(points[n], points[1], 2, previewColEdge)
  end
end

-- Call every frame while painting should be possible.
-- Returns true if a polygon finished THIS frame.
local function update()
  if not active then
    return false
  end

  -- Cursor position + render/capture gating:
  -- Match other spline tools: only interact when mouse is hovering terrain.
  -- This avoids broken WantCaptureMouse/isViewportHovered in some docking setups.
  local mousePos = util.mouseOnMapPos()
  cursorPos:set(mousePos)
  cursorPos.z = core_terrain.getTerrainHeight(cursorPos) + 0.05
  local hoveringTerrain = util.isMouseHoveringOverTerrain()

  -- Always render preview + cursor while armed/drawing.
  renderPreview()
  render.drawSphereCursor(cursorPos, hoveringTerrain)

  -- Capture gate:
  local canCapture = hoveringTerrain

  local mouseDown = im.IsMouseDown(0)

  -- IMPORTANT: Do not enter drawing state unless we can capture (mouse is actually over terrain).
  -- This prevents a UI click (e.g. pressing "New") from instantly starting+finishing the stroke.
  if mouseDown then
    if not canCapture then
      return false -- remain armed
    end
    if not drawing then
      drawing = true
    end
    if #points < 1 then
      addPoint(cursorPos)
      return false
    end
    if cursorPos:squaredDistance(lastP) >= stepSq then
      addPoint(cursorPos)
    end
    return false
  end

  -- Mouse released: finish only if we were drawing.
  if drawing then
    drawing = false
    if simplifyPolyline() then
      finished = true
      active = false
      return true
    end
    -- Not enough points: keep armed and discard the stroke.
    table.clear(points)
    table.clear(simplified)
    finished = false
    return false
  end

  -- Not down: remain armed.
  return false
end


-- Public interface.
M.start =                                               start
M.cancel =                                              cancel
M.isActive =                                            isActive
M.hasFinished =                                         hasFinished
M.consumePolygon =                                      consumePolygon
M.update =                                              update

return M