-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local logTag = 'drivelineEditSurface'

local drivelineUtil = require('/lua/ge/extensions/gameplay/rally/driveline/util')
local geom = require('editor/toolUtilities/geom')
local render = require('editor/toolUtilities/render')
local util = require('editor/toolUtilities/util')
local rdp = require('editor/toolUtilities/rdp')
local zSnap = require('/lua/ge/extensions/editor/rallyEditor/zSnap')

local M = {}

local function notifyBeforeMutation(host, opts, actionName)
  if opts and opts.onBeforeMutation then
    opts.onBeforeMutation(host, actionName)
  end
end

local function notifySplineMutated(host, opts, actionName)
  if opts and opts.onSplineMutated then
    opts.onSplineMutated(host, actionName)
  end
end

local function notifyCommit(host, opts, actionName)
  if opts and opts.onCommit then
    opts.onCommit(host, actionName)
  end
end

local function isInputBlocked(opts)
  if not opts then return false end
  if opts.inputBlocked then return true end
  if opts.isInputBlocked then return opts.isInputBlocked() end
  return false
end

local function snapNodeToDrivelineSurface(host, pos)
  local properties = host and host.drivelineV3 and host.drivelineV3.properties or nil
  return zSnap.snapDrivelineInPlace(pos, properties and properties.useRaycast, properties and properties.vertRayRaise)
end

function M.restoreSpline(host, saved)
  if not host or not host.drivelineV3 or not host.drivelineV3.spline or not saved then return end

  local spline = host.drivelineV3.spline
  table.clear(spline.nodes)
  for i = 1, #saved.nodes do
    spline.nodes[i] = vec3(saved.nodes[i])
  end

  table.clear(spline.widths)
  for i = 1, #saved.widths do
    spline.widths[i] = saved.widths[i]
  end

  table.clear(spline.nmls)
  for i = 1, #saved.nmls do
    spline.nmls[i] = vec3(saved.nmls[i])
  end

  spline.isDirty = true
  host.drivelineV3:updateSplineGeometry()
  host.drivelineV3:createDrivelineFromSpline()
end

function M.undoSplineEdit(host, data)
  if not data then return end
  M.restoreSpline(host, data.old)
end

function M.redoSplineEdit(host, data)
  if not data then return end
  M.restoreSpline(host, data.new)
end

function M.commitSplineEdit(host, actionName, oldSpline, opts)
  if not host or not host.drivelineV3 or not oldSpline then return end

  editor.history:commitAction(actionName,
    { old = oldSpline, new = host.drivelineV3:deepCopySpline() },
    function(d)
      M.undoSplineEdit(host, d)
      if opts and opts.onHistoryRestore then opts.onHistoryRestore(host, actionName, 'undo') end
    end,
    function(d)
      M.redoSplineEdit(host, d)
      if opts and opts.onHistoryRestore then opts.onHistoryRestore(host, actionName, 'redo') end
    end,
    true)

  notifyCommit(host, opts, actionName)
end

function M.refreshSplineGeometry(host, opts)
  if not host or not host.drivelineV3 or not host.drivelineV3.spline then return false end
  local spline = host.drivelineV3.spline
  if spline.isDirty and #spline.nodes >= 2 then
    if host.drivelineV3:updateSplineGeometry() then
      if not opts or opts.generateFinal ~= false then
        host.drivelineV3:createDrivelineFromSpline()
      end
      notifySplineMutated(host, opts, 'Update Spline Geometry')
      return true
    end
  end
  return false
end

function M.simplifySpline(host, tolerance, opts)
  if not host or not host.drivelineV3 or not host.drivelineV3.spline then return false end
  local spline = host.drivelineV3.spline
  if #spline.nodes <= 2 then return false end

  notifyBeforeMutation(host, opts, 'Simplify Spline')
  local preEdit = host.drivelineV3:deepCopySpline()
  rdp.simplifyNodesWidthsNormals(
    spline.nodes,
    spline.widths,
    spline.nmls,
    tolerance
  )
  host.selectedNodeIdx = math.max(1, math.min(#spline.nodes, host.selectedNodeIdx or 1))
  spline.isDirty = true
  M.refreshSplineGeometry(host, opts)
  M.commitSplineEdit(host, 'Simplify Spline', preEdit, opts)
  return true
end

function M.createFinalDriveline(host)
  if not host or not host.drivelineV3 then return false end
  return host.drivelineV3:createDrivelineFromSpline()
end

function M.saveFinalDriveline(host)
  if not host or not host.drivelineV3 then return false end
  if not host.drivelineV3.spline or not host.drivelineV3.spline.nodes or #host.drivelineV3.spline.nodes < 2 then
    log('E', logTag, 'No driveline spline handles to save')
    return false
  end

  if not host.path then
    log('E', logTag, 'Cannot save: no notebook path')
    return false
  end

  local missionDir = host.path:getMissionDir()
  if not missionDir then
    log('E', logTag, 'Cannot save: no mission directory')
    return false
  end

  host.drivelineV3.missionDir = missionDir
  return host.drivelineV3:saveSplineToFile()
end

function M.handleSplineInteraction(host, opts)
  if not host or not host.drivelineV3 or not host.drivelineV3.spline or not host.drivelineV3.spline.nodes then
    return
  end

  if im.GetIO().WantCaptureMouse or isInputBlocked(opts) then
    return
  end

  local mousePos = util.mouseOnMapPos()
  if not mousePos then
    return
  end

  local isDelDown = im.IsKeyDown(im.GetKeyIndex(im.Key_Delete))
  local isMouseDown = im.IsMouseDown(0)
  local isMouseClicked = im.IsMouseClicked(0)

  local ray = getCameraMouseRay()
  if not ray then
    return
  end
  local rayPos, rayDir = ray.pos, ray.dir

  local hitNodeIdx = nil
  local minNodeDist = math.huge

  for i, node in ipairs(host.drivelineV3.spline.nodes) do
    local dist = node:distance(rayPos)
    local tolerance = 0.5 + math.sqrt(dist) * 0.15
    local intA, intB = intersectsRay_Sphere(rayPos, rayDir, node, tolerance)
    if intA and intB then
      local hitDist = math.min(intA, intB)
      if hitDist < minNodeDist then
        minNodeDist = hitDist
        hitNodeIdx = i
      end
    end
  end

  if hitNodeIdx then
    render.drawSphereHighlightHover(host.drivelineV3.spline.nodes[hitNodeIdx])
    if isMouseClicked then
      notifyBeforeMutation(host, opts, 'Drag Node')
      host.selectedNodeIdx = hitNodeIdx
      host.dragState = {
        isDragging = true,
        nodeIdx = hitNodeIdx,
        preDrag = host.drivelineV3:deepCopySpline(),
        lastMousePos = vec3(mousePos)
      }
    end
  end

  if host.dragState and host.dragState.isDragging then
    if isMouseDown then
      local nodes = host.drivelineV3.spline.nodes
      local nodeIdx = host.dragState.nodeIdx
      local deltaXY = vec3(mousePos.x - host.dragState.lastMousePos.x,
                           mousePos.y - host.dragState.lastMousePos.y,
                           0)
      nodes[nodeIdx]:setAdd(deltaXY)
      snapNodeToDrivelineSurface(host, nodes[nodeIdx])

      host.dragState.lastMousePos = vec3(mousePos)
      host.drivelineV3.spline.isDirty = true
      notifySplineMutated(host, opts, 'Drag Node')
    else
      if host.dragState.preDrag then
        M.commitSplineEdit(host, 'Drag Node', host.dragState.preDrag, opts)
      end
      host.dragState = nil
    end
    return
  end

  local isOverCurve, idxLower, pHit = geom.isMouseOverSpline(host.drivelineV3.spline)

  if not hitNodeIdx and isOverCurve and pHit then
    render.drawSphereHighlightHover(pHit)
    render.drawSphereNode(pHit)
    render.markupInsertNode(pHit)
    if isMouseClicked then
      notifyBeforeMutation(host, opts, 'Insert Node')
      local preEdit = host.drivelineV3:deepCopySpline()
      local insertIdx = idxLower + 1
      table.insert(host.drivelineV3.spline.nodes, insertIdx, vec3(pHit))
      table.insert(host.drivelineV3.spline.widths, insertIdx, drivelineUtil.defaultSplineWidth)

      local prevNml = host.drivelineV3.spline.nmls[idxLower] or vec3(0, 0, 1)
      local nextNml = host.drivelineV3.spline.nmls[insertIdx] or vec3(0, 0, 1)
      table.insert(host.drivelineV3.spline.nmls, insertIdx, lerp(prevNml, nextNml, 0.5))

      host.selectedNodeIdx = insertIdx
      host.drivelineV3.spline.isDirty = true
      M.refreshSplineGeometry(host, opts)
      M.commitSplineEdit(host, 'Insert Node', preEdit, opts)
    end
    return
  end

  if not hitNodeIdx and not isOverCurve then
    render.drawSphereNode(mousePos)

    if isMouseClicked then
      notifyBeforeMutation(host, opts, 'Add Node')
      local preEdit = host.drivelineV3:deepCopySpline()
      local nodes = host.drivelineV3.spline.nodes
      local widths = host.drivelineV3.spline.widths
      local nmls = host.drivelineV3.spline.nmls

      if #nodes == 0 then
        table.insert(nodes, vec3(mousePos))
        table.insert(widths, drivelineUtil.defaultSplineWidth)
        table.insert(nmls, vec3(0, 0, 1))
        host.selectedNodeIdx = 1
      elseif #nodes == 1 then
        table.insert(nodes, vec3(mousePos))
        table.insert(widths, widths[1])
        table.insert(nmls, vec3(nmls[1] or vec3(0, 0, 1)))
        host.selectedNodeIdx = 2
      else
        local distToStart = mousePos:squaredDistance(nodes[1])
        local distToEnd = mousePos:squaredDistance(nodes[#nodes])

        if distToStart < distToEnd then
          table.insert(nodes, 1, vec3(mousePos))
          table.insert(widths, 1, widths[1])
          table.insert(nmls, 1, vec3(nmls[1] or vec3(0, 0, 1)))
          host.selectedNodeIdx = 1
        else
          table.insert(nodes, vec3(mousePos))
          table.insert(widths, widths[#widths])
          table.insert(nmls, vec3(nmls[#nmls] or vec3(0, 0, 1)))
          host.selectedNodeIdx = #nodes
        end
      end

      host.drivelineV3.spline.isDirty = true
      M.refreshSplineGeometry(host, opts)
      M.commitSplineEdit(host, 'Add Node', preEdit, opts)
    end
  end

  if isDelDown and not host.deletePressed then
    if host.selectedNodeIdx and host.selectedNodeIdx <= #host.drivelineV3.spline.nodes and #host.drivelineV3.spline.nodes > 2 then
      notifyBeforeMutation(host, opts, 'Delete Node')
      local preEdit = host.drivelineV3:deepCopySpline()
      table.remove(host.drivelineV3.spline.nodes, host.selectedNodeIdx)
      table.remove(host.drivelineV3.spline.widths, host.selectedNodeIdx)
      table.remove(host.drivelineV3.spline.nmls, host.selectedNodeIdx)
      host.selectedNodeIdx = math.max(1, math.min(#host.drivelineV3.spline.nodes, host.selectedNodeIdx))
      host.drivelineV3.spline.isDirty = true
      M.refreshSplineGeometry(host, opts)
      M.commitSplineEdit(host, 'Delete Node', preEdit, opts)

      host.deletePressed = true
    end
  elseif not isDelDown then
    host.deletePressed = false
  end
end

return M
