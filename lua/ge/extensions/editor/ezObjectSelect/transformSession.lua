-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local session = nil

local function copyMatrix(matrix)
  return matrix * MatrixF(true)
end

local function normalizedTangent(vector, normal)
  local tangent = vec3(vector) - normal * vec3(vector):dot(normal)
  local length = tangent:length()
  return length > 0.0001 and tangent / length or nil
end

local function alignedTransform(
  initialTransform,
  surfaceNormal,
  position,
  rotateSnapSize,
  rotateRelative)
  local normal = vec3(surfaceNormal)
  local normalLength = normal:length()
  if normalLength <= 0.0001 then
    local transform = copyMatrix(initialTransform)
    transform:setPosition(position)
    return transform
  end
  normal = normal / normalLength

  local initialForward = vec3(initialTransform:getColumn(1))
  local initialYaw = math.atan2(initialForward.y, initialForward.x)
  local yaw = initialYaw
  if rotateSnapSize and rotateSnapSize > 0 then
    local snapRadians = math.rad(rotateSnapSize)
    if rotateRelative then
      yaw = initialYaw + round((yaw - initialYaw) / snapRadians) * snapRadians
    else
      yaw = round(yaw / snapRadians) * snapRadians
    end
  end
  local cx, cy = math.cos(yaw), math.sin(yaw)
  local forward = normalizedTangent(vec3(cx, cy, 0), normal)
  if not forward then
    local initialRight = vec3(initialTransform:getColumn(0))
    local right = normalizedTangent(initialRight, normal)
    if right then forward = normal:cross(right) end
  end
  if not forward then
    local fallback = math.abs(normal.z) < 0.9 and vec3(0, 0, 1) or vec3(0, 1, 0)
    forward = normalizedTangent(fallback, normal)
  end
  forward:normalize()
  local right = forward:cross(normal)
  right:normalize()
  forward = normal:cross(right)
  forward:normalize()

  local transform = MatrixF(0)
  transform:setColumn(0, right)
  transform:setColumn(1, forward)
  transform:setColumn(2, normal)
  transform:setPosition(position)
  return transform
end

local function transformsDiffer(first, second)
  for column = 0, 3 do
    if (vec3(first:getColumn(column)) - vec3(second:getColumn(column))):length() > 0.0001 then
      return true
    end
  end
  return false
end

local function scalesDiffer(first, second)
  return first and second and (vec3(first) - vec3(second)):length() > 0.0001
end

local function refreshEditorState()
  if editor.computeSelectionBBox then editor.computeSelectionBBox() end
  if editor.updateObjectSelectionAxisGizmo then editor.updateObjectSelectionAxisGizmo() end
end

local function updatePrefabOffset(obj, objectId)
  local prefabInstance = Engine.Prefab.findContainingPrefabInstance(obj)
  if not prefabInstance then return end
  prefabInstance = Sim.upcast(prefabInstance)
  if prefabInstance and prefabInstance.updateChildOffsetTransform then
    prefabInstance:updateChildOffsetTransform(objectId)
  end
end

local function applyHistoryTransform(actionData, transform)
  local obj = Sim.findObjectById(actionData.objectId)
  if obj then
    obj:setTransform(editor.tableToMatrix(transform))
    updatePrefabOffset(obj, actionData.objectId)
  end
  refreshEditorState()
  extensions.hook("onEditorObjectSelectionTransformChanged")
end

local function setObjectTransformUndo(actionData)
  applyHistoryTransform(actionData, actionData.oldTransform)
end

local function setObjectTransformRedo(actionData)
  applyHistoryTransform(actionData, actionData.newTransform)
end

local function applyHistoryScale(actionData, scale)
  local obj = Sim.findObjectById(actionData.objectId)
  if obj and obj.setScale then
    obj:setScale(vec3(scale))
    updatePrefabOffset(obj, actionData.objectId)
  end
  refreshEditorState()
  extensions.hook("onEditorObjectSelectionTransformChanged")
end

local function setObjectScaleUndo(actionData)
  applyHistoryScale(actionData, actionData.oldScale)
end

local function setObjectScaleRedo(actionData)
  applyHistoryScale(actionData, actionData.newScale)
end

function M.begin(anchorObject, options)
  if session or not anchorObject or not editor.isObjectSelected(anchorObject:getID())
    or not editor.canManipulateObject(anchorObject) then
    return false
  end
  options = options or {}

  local objects = {}
  for _, id in ipairs(editor.selection.object or {}) do
    local obj = scenetree.findObjectById(id)
    if not obj or not obj.getTransform or not editor.canManipulateObject(obj) then return false end
    objects[#objects + 1] = {
      id = id,
      transform = copyMatrix(obj:getTransform()),
      scale = obj.getScale and vec3(obj:getScale()) or nil
    }
  end
  if #objects == 0 then return false end

  session = {
    anchorId = anchorObject:getID(),
    anchorPosition = vec3(anchorObject:getPosition()),
    objects = objects,
    grabOffset = nil,
    historyName = options.historyName or "EasySelectDrag"
  }
  return true
end

function M.setGrabSurface(surfacePosition, maintainRelativeZ, verticalOffset)
  if not session or not surfacePosition then return false end
  session.grabOffset = vec3(surfacePosition) - session.anchorPosition
  if verticalOffset ~= nil then
    session.grabOffset.z = verticalOffset
  elseif maintainRelativeZ == false then
    session.grabOffset.z = 0
  end
  return true
end

local function snapAnchorPosition(desiredAnchorPosition, options)
  if not options.gridSize or options.gridSize <= 0 then return desiredAnchorPosition end
  if options.gridRelative then
    local delta = desiredAnchorPosition - session.anchorPosition
    delta.x = round(delta.x / options.gridSize) * options.gridSize
    delta.y = round(delta.y / options.gridSize) * options.gridSize
    if options.snapZ then delta.z = round(delta.z / options.gridSize) * options.gridSize end
    return session.anchorPosition + delta
  end

  desiredAnchorPosition.x = round(desiredAnchorPosition.x / options.gridSize) * options.gridSize
  desiredAnchorPosition.y = round(desiredAnchorPosition.y / options.gridSize) * options.gridSize
  if options.snapZ then
    desiredAnchorPosition.z = round(desiredAnchorPosition.z / options.gridSize) * options.gridSize
  end
  return desiredAnchorPosition
end

function M.getDesiredAnchorPosition(surfacePosition, options)
  if not session or not session.grabOffset or not surfacePosition then return false end
  options = options or {}
  local desiredAnchorPosition = vec3(surfacePosition) - session.grabOffset
  return snapAnchorPosition(desiredAnchorPosition, options)
end

function M.updateDelta(delta, options)
  if not session or not delta then return false end
  options = options or {}
  local snappedDelta = vec3(delta)
  if options.gridSize and options.gridSize > 0 and options.gridPivot then
    local gridMask = options.gridMask or {x = true, y = true, z = true}
    if options.gridRelative then
      if gridMask.x then
        snappedDelta.x = round(snappedDelta.x / options.gridSize) * options.gridSize
      end
      if gridMask.y then
        snappedDelta.y = round(snappedDelta.y / options.gridSize) * options.gridSize
      end
      if options.snapZ and gridMask.z then
        snappedDelta.z = round(snappedDelta.z / options.gridSize) * options.gridSize
      end
    else
      local desiredPivot = vec3(options.gridPivot) + snappedDelta
      if gridMask.x then
        desiredPivot.x = round(desiredPivot.x / options.gridSize) * options.gridSize
      end
      if gridMask.y then
        desiredPivot.y = round(desiredPivot.y / options.gridSize) * options.gridSize
      end
      if options.snapZ and gridMask.z then
        desiredPivot.z = round(desiredPivot.z / options.gridSize) * options.gridSize
      end
      snappedDelta = desiredPivot - vec3(options.gridPivot)
    end
  else
    local desiredAnchorPosition = snapAnchorPosition(
      session.anchorPosition + snappedDelta,
      options)
    snappedDelta = desiredAnchorPosition - session.anchorPosition
  end
  for _, entry in ipairs(session.objects) do
    local obj = scenetree.findObjectById(entry.id)
    if obj then
      local transform = copyMatrix(entry.transform)
      transform:setPosition(entry.transform:getColumn(3) + snappedDelta)
      obj:setTransform(transform)
    end
  end
  refreshEditorState()
  return true
end

function M.updateRotation(pivot, axis, angle)
  if not session or not pivot or not axis or not angle then return false end
  local rotationAxis = vec3(axis)
  if rotationAxis:length() <= 0.0001 then return false end
  rotationAxis:normalize()
  local deltaRotation = quatFromAxisAngle(rotationAxis, angle)
  local center = vec3(pivot)
  for _, entry in ipairs(session.objects) do
    local obj = scenetree.findObjectById(entry.id)
    if obj then
      local transform = MatrixF(0)
      for column = 0, 2 do
        transform:setColumn(column, deltaRotation * vec3(entry.transform:getColumn(column)))
      end
      local offset = vec3(entry.transform:getColumn(3)) - center
      transform:setPosition(center + deltaRotation * offset)
      obj:setTransform(transform)
    end
  end
  refreshEditorState()
  return true
end

function M.updateScale(pivot, axes, factors)
  if not session or not pivot or not axes or not factors then return false end
  local minimumScale, maximumScale = 0.01, 1000
  local requested = {
    x = math.max(factors.x or 1, 0.0001),
    y = math.max(factors.y or 1, 0.0001),
    z = math.max(factors.z or 1, 0.0001)
  }
  local edited = {}
  local requestedFactor = 1
  for _, name in ipairs({"x", "y", "z"}) do
    if math.abs(requested[name] - 1) > 0.000001 then
      edited[name] = true
      requestedFactor = requested[name]
    end
  end
  local lower, upper = 0.0001, math.huge
  for _, entry in ipairs(session.objects) do
    if entry.scale then
      for _, name in ipairs({"x", "y", "z"}) do
        if edited[name] then
          local initial = math.max(math.abs(entry.scale[name]), 0.0001)
          lower = math.max(lower, minimumScale / initial)
          upper = math.min(upper, maximumScale / initial)
        end
      end
    end
  end
  local clampedFactor = clamp(requestedFactor, lower, upper)
  local effective = {x = 1, y = 1, z = 1}
  for name in pairs(edited) do effective[name] = clampedFactor end

  local function scaledComponent(value, factor, isEdited)
    if not isEdited then return value end
    local sign = value < 0 and -1 or 1
    return sign * clamp(math.abs(value) * factor, minimumScale, maximumScale)
  end

  local center = vec3(pivot)
  for _, entry in ipairs(session.objects) do
    local obj = scenetree.findObjectById(entry.id)
    if obj then
      if entry.scale and obj.setScale then
        obj:setScale(vec3(
          scaledComponent(entry.scale.x, effective.x, edited.x),
          scaledComponent(entry.scale.y, effective.y, edited.y),
          scaledComponent(entry.scale.z, effective.z, edited.z)))
      end
      local offset = vec3(entry.transform:getColumn(3)) - center
      local scaledOffset = vec3(0, 0, 0)
      for _, name in ipairs({"x", "y", "z"}) do
        local axis = vec3(axes[name])
        scaledOffset = scaledOffset + axis * offset:dot(axis) * effective[name]
      end
      local transform = copyMatrix(entry.transform)
      transform:setPosition(center + scaledOffset)
      obj:setTransform(transform)
    end
  end
  refreshEditorState()
  return true, clampedFactor
end

function M.update(surfacePosition, surfaceNormal, options)
  local desiredAnchorPosition = M.getDesiredAnchorPosition(surfacePosition, options)
  if not desiredAnchorPosition then return false end
  local delta = desiredAnchorPosition - session.anchorPosition

  for _, entry in ipairs(session.objects) do
    local obj = scenetree.findObjectById(entry.id)
    if obj then
      local position = entry.transform:getColumn(3) + delta
      local objectNormal = surfaceNormal
      if options.individualProvider then
        local individual = options.individualProvider(entry, vec3(position))
        if individual then
          position = individual.position or position
          objectNormal = individual.normal or objectNormal
        end
      end
      local transform = options.followRotation and objectNormal
        and alignedTransform(
          entry.transform,
          objectNormal,
          position,
          options.rotateSnapSize,
          options.rotateRelative)
        or copyMatrix(entry.transform)
      transform:setPosition(position)
      obj:setTransform(transform)
    end
  end
  refreshEditorState()
  return true
end

function M.finish()
  if not session then return false end
  local completedSession = session
  local hasNetChange = false
  for _, entry in ipairs(completedSession.objects) do
    local obj = scenetree.findObjectById(entry.id)
    if obj and (transformsDiffer(obj:getTransform(), entry.transform)
      or scalesDiffer(obj.getScale and obj:getScale() or nil, entry.scale)) then
      hasNetChange = true
      break
    end
  end

  if not hasNetChange then
    for _, entry in ipairs(completedSession.objects) do
      local obj = scenetree.findObjectById(entry.id)
      if obj then
        obj:setTransform(copyMatrix(entry.transform))
        if entry.scale and obj.setScale then obj:setScale(vec3(entry.scale)) end
        updatePrefabOffset(obj, entry.id)
      end
    end
  end

  if hasNetChange then
    if not editor.history:beginTransaction(completedSession.historyName) then
      for _, entry in ipairs(completedSession.objects) do
        local obj = scenetree.findObjectById(entry.id)
        if obj then
          obj:setTransform(copyMatrix(entry.transform))
          if entry.scale and obj.setScale then obj:setScale(vec3(entry.scale)) end
          updatePrefabOffset(obj, entry.id)
        end
      end
      session = nil
      refreshEditorState()
      return nil
    end
    for _, entry in ipairs(completedSession.objects) do
      local obj = scenetree.findObjectById(entry.id)
      if obj then
        local transformChanged = transformsDiffer(obj:getTransform(), entry.transform)
        if transformChanged then
          editor.history:commitAction(
            "SetObjectTransform",
            {
              objectId = entry.id,
              newTransform = editor.matrixToTable(obj:getTransform()),
              oldTransform = editor.matrixToTable(entry.transform)
            },
            setObjectTransformUndo,
            setObjectTransformRedo,
            true
          )
        else
          obj:setTransform(copyMatrix(entry.transform))
        end
        local newScale = obj.getScale and vec3(obj:getScale()) or nil
        if scalesDiffer(newScale, entry.scale) then
          editor.history:commitAction(
            "SetObjectScale",
            {
              objectId = entry.id,
              newScale = newScale,
              oldScale = vec3(entry.scale)
            },
            setObjectScaleUndo,
            setObjectScaleRedo,
            true
          )
        elseif entry.scale and obj.setScale then
          obj:setScale(vec3(entry.scale))
        end
        updatePrefabOffset(obj, entry.id)
      end
    end
    editor.history:endTransaction(true)
    editor.setDirty()
  end

  local completion
  if hasNetChange then
    local anchor = scenetree.findObjectById(completedSession.anchorId)
    completion = {
      anchorDistance = anchor
        and (vec3(anchor:getPosition()) - completedSession.anchorPosition):length()
        or 0
    }
  end
  session = nil
  refreshEditorState()
  return hasNetChange, completion
end

function M.cancel()
  if not session then return false end
  for _, entry in ipairs(session.objects) do
    local obj = scenetree.findObjectById(entry.id)
    if obj then
      obj:setTransform(copyMatrix(entry.transform))
      if entry.scale and obj.setScale then obj:setScale(vec3(entry.scale)) end
      updatePrefabOffset(obj, entry.id)
    end
  end
  session = nil
  refreshEditorState()
  return true
end

local function uprightTransform(transform)
  local forward = vec3(transform:getColumn(1))
  forward.z = 0
  local forwardLength = forward:length()
  if forwardLength <= 0.0001 then
    local right = vec3(transform:getColumn(0))
    right.z = 0
    local rightLength = right:length()
    forward = rightLength > 0.0001
      and vec3(0, 0, 1):cross(right / rightLength)
      or vec3(0, 1, 0)
  else
    forward = forward / forwardLength
  end

  local up = vec3(0, 0, 1)
  local result = MatrixF(true)
  result:setColumn(0, forward:cross(up))
  result:setColumn(1, forward)
  result:setColumn(2, up)
  result:setPosition(transform:getColumn(3))
  return result
end

function M.resetRotation(objectIds)
  if session then return false end
  local changes = {}
  for _, id in ipairs(objectIds or {}) do
    local obj = scenetree.findObjectById(id)
    if obj and obj.getTransform and editor.canManipulateObject(obj) then
      local oldTransform = copyMatrix(obj:getTransform())
      local newTransform = uprightTransform(oldTransform)
      if transformsDiffer(oldTransform, newTransform) then
        changes[#changes + 1] = {
          id = id,
          obj = obj,
          oldTransform = oldTransform,
          newTransform = newTransform
        }
      end
    end
  end
  if #changes == 0 then return false end

  if not editor.history:beginTransaction("ResetObjectRotation") then return false end
  for _, change in ipairs(changes) do
    change.obj:setTransform(change.newTransform)
    editor.history:commitAction(
      "SetObjectTransform",
      {
        objectId = change.id,
        newTransform = editor.matrixToTable(change.newTransform),
        oldTransform = editor.matrixToTable(change.oldTransform)
      },
      setObjectTransformUndo,
      setObjectTransformRedo,
      true
    )
    updatePrefabOffset(change.obj, change.id)
  end
  editor.history:endTransaction(true)
  editor.setDirty()
  refreshEditorState()
  return true
end

function M.isActive()
  return session ~= nil
end

function M.selectionMatches()
  if not session then return true end
  local selected = editor.selection.object or {}
  if #selected ~= #session.objects then return false end
  local selectedIds = {}
  for _, id in ipairs(selected) do selectedIds[id] = true end
  for _, entry in ipairs(session.objects) do
    if not selectedIds[entry.id] then return false end
    local obj = scenetree.findObjectById(entry.id)
    if not obj or not obj.getTransform or not editor.canManipulateObject(obj) then return false end
  end
  return true
end

function M.getObjectIds()
  if not session then return {} end
  local ids = {}
  for _, entry in ipairs(session.objects) do ids[#ids + 1] = entry.id end
  return ids
end

return M
