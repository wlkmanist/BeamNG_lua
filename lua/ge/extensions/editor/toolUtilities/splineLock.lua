-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared lock state for the custom spline tools. A LOCKED spline (isEnabled == false) stays in its tool, but its generated
-- objects are the level's: they save with it (canSave=true) and collide. An UNLOCKED spline's objects are the tool's live
-- preview: transient (canSave=false) and without collision. Each tool calls sync() from its rebuild, so every way the flag
-- can change (lock button, burn, undo/redo, Lua reload, Master Spline) ends up in the same place.
-- While locked, the tool never moves or remakes a spline's objects that still exist: hand edits stand until it is unlocked.
--
-- Each tool provides `each(fn)`, calling fn(obj, collides, isParked) for every object it owns for the spline: `collides` as in
-- applyObject, `isParked` for owned objects that are not part of the result (kept hidden for reuse), which are left as they are.

local M = {}


-- Drops handles to objects that are gone (e.g. deleted by hand in the scene tree), compacting the list in place.
local function dropDeleted(list)
  local n, j = #list, 0
  for i = 1, n do
    local o = list[i]
    list[i] = nil
    if o and simObjectExists(o) then
      j = j + 1
      list[j] = o
    end
  end
end

-- Marks a generated object with the spline it came from, so it can be traced back from the scene tree / inspector.
local function tag(obj, toolName, spline)
  obj:setDynDataFieldbyName('sourceTool', 0, toolName)
  obj:setDynDataFieldbyName('sourceSplineId', 0, tostring(spline.id))
  obj:setDynDataFieldbyName('sourceSplineName', 0, spline.name or '')
end

-- Makes one generated object match the lock state. `collides` = whether it collides once locked; nil leaves collision alone.
local function applyObject(obj, isLocked, collides)
  obj.canSave = isLocked
  if collides ~= nil then
    obj:setField('collisionType', 0, (isLocked and collides) and 'Collision Mesh' or 'None')
  end
end

-- True if the tool still owns at least one live (not parked) object for the spline.
local function hasAny(each)
  local found = false
  each(function(obj, _, isParked) if not found and not isParked and obj and simObjectExists(obj) then found = true end end)
  return found
end

-- Roads and rivers are laid by their nodes, not posed by a transform: capture/restore leave them to the tool.
local nodeLaid = { DecalRoad = true, MeshRoad = true, River = true }

-- An owned object capture/restore deals with.
local function isPosed(obj, isParked)
  return not isParked and obj and simObjectExists(obj) and not nodeLaid[obj:getClassName()]
end

-- Brings a spline's generated objects in line with its lock state. Only acts when the state differs from the last one applied
-- (`applied`: the tool's id -> isLocked table), as new objects are created in the right state. Returns true if it acted.
local function sync(applied, spline, toolName, each)
  local isLocked = not spline.isEnabled
  local prev = applied[spline.id]
  if prev == nil then prev = false end -- objects are created in the live state; nothing to do for a fresh unlocked spline.
  applied[spline.id] = isLocked
  if prev == isLocked then return false end
  local folder = spline.sceneTreeFolderId and scenetree.findObjectById(spline.sceneTreeFolderId)
  if folder then
    folder.canSave = isLocked
    tag(folder, toolName, spline)
  end
  local owned = {}
  each(function(obj, collides, isParked)
    if obj and simObjectExists(obj) then
      owned[obj:getId()] = true
      if not isParked then
        applyObject(obj, isLocked, collides)
        tag(obj, toolName, spline)
        if folder and obj:getGroup() and obj:getGroup():getId() ~= folder:getId() then folder:addObject(obj) end -- moved by hand: back home.
      end
    end
  end)
  -- Unlocking: anything else in the folder carrying this spline's tag (duplicated by hand, or brought back by undoing a
  -- delete, while locked) is not the tool's, and would double up with what the tool rebuilds.
  if folder and not isLocked then
    local strays, id = {}, tostring(spline.id)
    for i = 0, folder:getCount() - 1 do
      local o = folder:getObject(i)
      if o and not owned[o:getId()] and o:getDynDataFieldbyName('sourceSplineId', 0) == id then strays[#strays + 1] = o end
    end
    for i = 1, #strays do strays[i]:delete() end
  end
  be:reloadCollision()
  return true
end

-- Records the hand-editable state of a spline's objects (pose, scale, shape, folder), keyed by object id. Taken before an
-- unlock resets them, so undoing the unlock can put the hand edits back.
local function capture(each)
  local rec = {}
  each(function(obj, _, isParked)
    if isPosed(obj, isParked) then
      local g = obj:getGroup()
      rec[obj:getId()] = {
        xf = editor.matrixToTable(obj:getTransform()),
        scale = vec3(obj:getScale()),
        shape = obj:getClassName() == 'TSStatic' and obj:getField('shapeName', 0) or nil,
        groupId = g and g:getId(),
      }
    end
  end)
  return rec
end

-- Puts a capture back, after the re-lock that undoes an unlock. Objects the unlock made in the meantime (for ones deleted by
-- hand while locked) are deleted again.
local function restore(rec, each)
  local made = {}
  each(function(obj, _, isParked)
    if not isPosed(obj, isParked) then return end
    local r = rec[obj:getId()]
    if not r then made[#made + 1] = obj; return end
    if r.shape and obj:getField('shapeName', 0) ~= r.shape then
      obj:setField('shapeName', 0, r.shape)
      obj:postApply()
    end
    obj:setTransform(editor.tableToMatrix(r.xf))
    obj:setScale(r.scale)
    local g = obj:getGroup()
    if r.groupId and (not g or g:getId() ~= r.groupId) then
      local home = scenetree.findObjectById(r.groupId)
      if home then home:addObject(obj) end
    end
  end)
  for i = 1, #made do made[i]:delete() end
  be:reloadCollision()
end


-- Public interface.
M.dropDeleted = dropDeleted
M.tag = tag
M.applyObject = applyObject
M.hasAny = hasAny
M.sync = sync
M.capture = capture
M.restore = restore

return M