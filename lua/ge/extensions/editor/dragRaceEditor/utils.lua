-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local constants = require('/lua/ge/extensions/editor/dragRaceEditor/constants')
local state = require('/lua/ge/extensions/editor/dragRaceEditor/state')
local im = ui_imgui

local M = {}

M.logError = function(message)
  state.setLastError(message)
  state.setErrorTimeout(3)
  log('E', 'DragRaceEditor', message)
end

M.showError = function()
  local lastError = state.getLastError()
  local errorTimeout = state.getErrorTimeout()

  if lastError and errorTimeout > 0 then
    im.TextColored(constants.CONSTANTS.COLORS.ERROR, "Error: " .. lastError)
    state.setErrorTimeout(errorTimeout - im.GetIO().DeltaTime)
    if state.getErrorTimeout() <= 0 then
      state.setLastError(nil)
    end
  end
end

M.markUnsavedChanges = function()
  state.setHasUnsavedChanges(true)
end

M.clearUnsavedChanges = function()
  state.setHasUnsavedChanges(false)
end

M.saveToUndoStack = function()
  local undoStack = state.getUndoStack()
  local maxUndoSteps = state.getMaxUndoSteps()
  local dragRaceData = state.getDragRaceData()

  if #undoStack >= maxUndoSteps then
    table.remove(undoStack, 1)
  end
  table.insert(undoStack, deepcopy(dragRaceData))
  state.setRedoStack({})
end

M.undo = function()
  local undoStack = state.getUndoStack()
  local redoStack = state.getRedoStack()
  local dragRaceData = state.getDragRaceData()

  if #undoStack > 0 then
    table.insert(redoStack, dragRaceData)
    state.setDragRaceData(table.remove(undoStack))
    M.markUnsavedChanges()
  end
end

M.redo = function()
  local undoStack = state.getUndoStack()
  local redoStack = state.getRedoStack()
  local dragRaceData = state.getDragRaceData()

  if #redoStack > 0 then
    table.insert(undoStack, dragRaceData)
    state.setDragRaceData(table.remove(redoStack))
    M.markUnsavedChanges()
  end
end

M.validateDragRaceData = function(data)
  if not data then return false, "No data provided" end

  if data.stripId and data.stripId ~= "" then
    if not data.dragType or data.dragType == "" then
      return false, "Drag type not selected"
    end
    return true
  end

  if data.strip and data.strip.lanes then
    if not data.dragType or data.dragType == "" then
      return false, "Drag type not selected"
    end
    return true
  end

  return false, "Invalid data format - missing strip data or stripId"
end

M.createNewLane = function(laneIndex)
  return {
    shortName = "Lane " .. laneIndex,
    longName = "Lane " .. laneIndex,
    laneOrder = laneIndex,
    color = "blue",
    waypoints = {
      {
        type = "stage",
        transform = deepcopy(constants.CONSTANTS.DEFAULT_TRANSFORM)
      },
      {
        type = "endLine",
        transform = deepcopy(constants.CONSTANTS.DEFAULT_TRANSFORM)
      }
    },
    boundary = {
      transform = deepcopy(constants.CONSTANTS.DEFAULT_TRANSFORM)
    }
  }
end

M.createNewDragRaceData = function()
  return {
    canBeReseted = true,
    canBeTeleported = true,
    context = "activity",
    dragType = "headsUpRace",
    stripId = "",
    phases = {
      {
        dependency = true,
        name = "stage",
        startedOffset = 0
      },
      {
        dependency = false,
        name = "countdown",
        startedOffset = 0
      },
      {
        dependency = false,
        name = "race",
        startedOffset = 0
      },
      {
        dependency = false,
        name = "stop",
        startedOffset = 0
      }
    },
    prefabs = {
      christmasTree = {
        isUsed = false,
        treeType = ".500"
      },
      displaySign = {
        isUsed = false
      },
      paths = {
        isUsed = false
      },
      decorations = {
        isUsed = false
      }
    }
  }
end

M.reorderLanes = function(t, old, new)
  local value = t[old]
  if new < old then
     table.move(t, new, old - 1, new + 1)
  else
     table.move(t, old + 1, new, old)
  end
  t[new] = value
end

M.updateMouseInfo = function()
  local mouseInfo = state.getMouseInfo()
  if not mouseInfo then mouseInfo = {} end

  if core_forest.getForestObject() then core_forest.getForestObject():disableCollision() end
  mouseInfo.camPos = core_camera.getPosition()
  mouseInfo.ray = getCameraMouseRay()
  mouseInfo.rayDir = vec3(mouseInfo.ray.dir)
  mouseInfo.rayCast = cameraMouseRayCast()
  mouseInfo.valid = mouseInfo.rayCast and true or false

  if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end
  if not mouseInfo.valid then
    mouseInfo.down = false
    mouseInfo.hold = false
    mouseInfo.up   = false
    mouseInfo.closestNodeHovered = nil
  else
    mouseInfo.down =  im.IsMouseClicked(0) and not im.GetIO().WantCaptureMouse
    mouseInfo.hold = im.IsMouseDown(0) and not im.GetIO().WantCaptureMouse
    mouseInfo.up =  im.IsMouseReleased(0) and not im.GetIO().WantCaptureMouse
    if mouseInfo.down then
      mouseInfo.hold = false
      mouseInfo._downPos = vec3(mouseInfo.rayCast.pos)
      mouseInfo._downNormal = vec3(mouseInfo.rayCast.normal)
    end
    if mouseInfo.hold then
      mouseInfo._holdPos = vec3(mouseInfo.rayCast.pos)
      mouseInfo._holdNormal = vec3(mouseInfo.rayCast.normal)
    end
    if mouseInfo.up then
      mouseInfo._upPos = vec3(mouseInfo.rayCast.pos)
      mouseInfo._upNormal = vec3(mouseInfo.rayCast.normal)
    end
  end

  state.setMouseInfo(mouseInfo)
end

M.setupTransform = function(label, transform, allowTranslate, allowRotate, allowScale)
  local transformUtil = require('/lua/ge/extensions/editor/util/transformUtil')(label, label)
  transformUtil.allowTranslate = allowTranslate ~= false
  transformUtil.allowRotate = allowRotate ~= false
  transformUtil.allowScale = allowScale ~= false

  local pos = vec3(transform.position.x, transform.position.y, transform.position.z)
  local rot = quat(transform.rotation.x, transform.rotation.y, transform.rotation.z, transform.rotation.w)
  local scl = vec3(transform.scale.x, transform.scale.y, transform.scale.z)

  transformUtil:set(pos, rot, scl)
  return transformUtil
end

-- Visible label safe for ImGui (avoid '#' in user strings breaking IDs).
M.dragHeaderLabel = function(s)
  if s == nil or s == "" then
    return "Untitled"
  end
  return tostring(s):gsub("#", "")
end

-- Collapsible section; default editor header colors, slightly taller hit area.
M.dragSectionHeader = function(visibleLabel, idSuffix, defaultOpen)
  local flags = defaultOpen and im.TreeNodeFlags_DefaultOpen or im.TreeNodeFlags_DefaultClosed
  im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(12, 8))
  local opened = im.CollapsingHeader1(M.dragHeaderLabel(visibleLabel) .. idSuffix, flags)
  im.PopStyleVar(1)
  return opened
end

return M
