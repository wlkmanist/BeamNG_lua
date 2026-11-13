-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- World Editor tools: activate editor, selection, undo/redo, edit modes, save level.

local M = {}

local function ensureEditor()
  if editor then return true end
  extensions.load('editor_main')
  return editor ~= nil
end

local function requireEditor(needActive)
  if not ensureEditor() then return "editor_main failed to load", true end
  if not editor.initialized and needActive then
    return "editor not initialized yet (activate it first with set_editor_active)", true
  end
  if needActive and not editor.active then
    return "editor not active (call set_editor_active with active=true)", true
  end
  return nil
end

local function objName(obj)
  return (obj.getName and obj:getName()) or obj:getField("name", "0") or ""
end

local function selectionObjects()
  local out = {}
  for _, id in ipairs((editor.getObjectSelection and editor.getObjectSelection()) or {}) do
    local obj = scenetree.findObjectById(id)
    if obj then
      out[#out + 1] = { id = id, name = objName(obj), class = obj:getClassName() }
    else
      out[#out + 1] = { id = id }
    end
  end
  return out
end

local function resolveIds(args)
  args = args or {}
  local ids = {}
  local function add(id)
    id = tonumber(id)
    if id then ids[#ids + 1] = id end
  end
  if type(args.ids) == "table" then for _, id in ipairs(args.ids) do add(id) end end
  if args.id ~= nil then add(args.id) end
  if args.name then
    local obj = scenetree.findObject(args.name)
    if obj then add(obj:getID()) end
  end
  return ids
end

local function selectModeFrom(args)
  local m = args and args.mode
  if m == "add" or m == editor.SelectMode_Add then return editor.SelectMode_Add end
  if m == "remove" or m == editor.SelectMode_Remove then return editor.SelectMode_Remove end
  if m == "toggle" or m == editor.SelectMode_Toggle then return editor.SelectMode_Toggle end
  return editor.SelectMode_New
end

-- Editor on/off, dirty flag, current level, edit mode, selection count, undo/redo depth.
function M.editor_status()
  if not ensureEditor() then return "editor_main not loaded", true end
  local hist = editor.history
  return jsonEncode({
    active = editor.active == true,
    initialized = editor.initialized == true,
    dirty = editor.dirty == true,
    levelName = editor.getLevelName and editor.getLevelName() or "",
    levelPath = editor.getLevelPath and editor.getLevelPath() or "",
    editMode = editor.getCurrentEditModeName and editor.getCurrentEditModeName() or "",
    selectionCount = #(selectionObjects()),
    undoCount = hist and hist.undoStack and #hist.undoStack or 0,
    redoCount = hist and hist.redoStack and #hist.redoStack or 0,
    headless = editor.headless == true,
  }), false
end

-- Activate or deactivate the World Editor (async over a couple frames).
function M.set_editor_active(args)
  if not ensureEditor() then return "editor_main failed to load", true end
  if args == nil or args.active == nil then return "missing 'active' boolean", true end
  local want = args.active == true
  editor.setEditorActive(want, args.safeMode == true)
  return want and "editor activating" or "editor deactivating", false
end

-- Currently selected scene objects: [{id, name, class}, ...].
function M.get_editor_selection()
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  local objects = selectionObjects()
  return jsonEncode({ count = #objects, objects = objects }), false
end

-- Select objects by id / ids / name. mode: new (default), add, remove, toggle.
function M.select_editor_objects(args)
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  local ids = resolveIds(args)
  if #ids == 0 then return "provide 'id', 'ids', or 'name'", true end
  editor.selectObjects(ids, selectModeFrom(args))
  return jsonEncode({ count = #ids, ids = ids }), false
end

function M.clear_editor_selection()
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  editor.clearObjectSelection()
  return "selection cleared", false
end

-- Delete the current object selection (undoable via editor history).
function M.delete_editor_selection()
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  local n = #selectionObjects()
  if n == 0 then return "nothing selected", true end
  if editor.deleteSelectedObjects then
    editor.deleteSelectedObjects()
  else
    editor.deleteSelection()
  end
  return "deleted " .. n .. " selected object(s)", false
end

function M.editor_undo(args)
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  local steps = tonumber(args and args.steps) or 1
  editor.undo(steps)
  return "undid " .. steps .. " step(s)", false
end

function M.editor_redo(args)
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  local steps = tonumber(args and args.steps) or 1
  editor.redo(steps)
  return "redid " .. steps .. " step(s)", false
end

function M.list_edit_modes()
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  local modes = {}
  for name in pairs(editor.editModes or {}) do modes[#modes + 1] = name end
  table.sort(modes)
  return jsonEncode({ current = editor.getCurrentEditModeName and editor.getCurrentEditModeName() or "", modes = modes }), false
end

-- Switch World Editor edit mode by registered name (from list_edit_modes).
function M.set_edit_mode(args)
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  local name = args and args.name
  if type(name) ~= "string" then return "missing 'name' (from list_edit_modes)", true end
  local mode = editor.editModes and editor.editModes[name]
  if not mode then return "unknown edit mode: " .. name, true end
  editor.selectEditMode(mode)
  return "edit mode set to " .. name, false
end

-- Frame the free/editor camera on the current selection.
function M.fit_view_to_selection()
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  if not editor.fitViewToSelectionSmooth and not editor.fitViewToSelection then
    return "fitViewToSelection unavailable", true
  end
  if #(selectionObjects()) == 0 then return "nothing selected", true end
  if editor.fitViewToSelectionSmooth then
    editor.fitViewToSelectionSmooth()
  else
    editor.fitViewToSelection()
  end
  return "camera fitted to selection", false
end

-- Resolve a level folder/mis path from args.name (list_levels) or args.path.
local function resolveLevelPath(args)
  args = args or {}
  local p = args.path
  if not p and args.name then
    if core_levels and core_levels.getList then
      for _, l in ipairs(core_levels.getList() or {}) do
        if l.levelName == args.name then
          p = l.fullfilename or l.misFilePath
          break
        end
      end
    end
    if not p and path and path.getPathLevelMain then p = path.getPathLevelMain(args.name) end
  end
  return p
end

-- Open a level through the World Editor (discards unsaved editor changes; async asset load).
function M.editor_load_level(args)
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  if not editor.openLevel then return "editor.openLevel unavailable", true end
  local p = resolveLevelPath(args)
  if not p then return "provide 'name' (from list_levels) or 'path' (level folder or main file)", true end
  -- editor.openLevel expects a level folder (with trailing /) when opened via the UI
  if not tostring(p):match("%.%w+$") and not tostring(p):match("/$") then p = p .. "/" end
  editor.openLevel(p)
  -- openLevel force-sets editor.active=true before the mission starts, so
  -- onClientStartMission's setEditorActiveInternal(true) thinks the editor is
  -- already active and skips the F11 activate path (CEF/HUD hide, action maps).
  -- Clear it so reactivation actually runs.
  editor.active = false
  return "loading level in editor: " .. tostring(p), false
end

-- Save the current level (MissionGroup). Editor must be active; level must be dirty-capable.
function M.editor_save_level()
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  local levelPath = editor.getLevelPath and editor.getLevelPath() or ""
  if levelPath == "" then return "no level path (open a level first)", true end
  editor.saveLevel()
  return "saved level: " .. levelPath, false
end

local NO_MESH_SHAPE = "/core/art/shapes/no_mesh.dae"

local function createObjectUndo(actionData)
  local obj = Sim.findObjectById(actionData.objectId)
  if obj then
    actionData.serializedData = "[" .. obj:serialize(true, -1) .. "]"
    editor.deleteObject(actionData.objectId)
  end
end

local function createObjectRedo(actionData)
  if actionData.objectId then
    SimObject.setForcedId(actionData.objectId)
    Sim.deserializeObjectsFromText(actionData.serializedData, true, true)
  end
end

local function resolveParent(args)
  if args and args.parentId then
    return scenetree.findObjectById(tonumber(args.parentId))
  end
  if args and args.parent then
    return scenetree.findObject(args.parent)
  end
  if editor.getCurrentSelectedParent then
    local p = editor.getCurrentSelectedParent()
    if p then return p end
  end
  return scenetree.MissionGroup
end

local function defaultCreatePos()
  if core_camera then
    local camPos = core_camera.getPosition()
    local fwd = core_camera.getForward()
    if camPos and fwd then return camPos + fwd:normalized() * 10 end
  end
  return vec3(0, 0, 0)
end

-- List SimObject-derived class names (optional substring filter). Useful before create_editor_object.
function M.list_editor_classes(args)
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  if type(Sim.getSimObjectDerivedClassNames) ~= "function" then
    return "Sim.getSimObjectDerivedClassNames unavailable", true
  end
  local pat = args and args.pattern and tostring(args.pattern):lower()
  local out = {}
  for _, name in ipairs(Sim.getSimObjectDerivedClassNames() or {}) do
    if not pat or tostring(name):lower():find(pat, 1, true) then
      out[#out + 1] = name
      if #out >= 500 then break end
    end
  end
  table.sort(out)
  return jsonEncode({ count = #out, classes = out }), false
end

-- Create a scene object (any SimObject class). Defaults to TSStatic.
-- For TSStatic pass shape/shapeName (dae/mesh path); falls back to the editor no-mesh placeholder.
function M.create_editor_object(args)
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  args = args or {}
  local classname = args.class or args.classname or "TSStatic"
  if type(classname) ~= "string" or classname == "" then return "missing 'class' (e.g. TSStatic, PointLight, SimGroup)", true end
  if type(worldEditorCppApi.createObject) ~= "function" then return "worldEditorCppApi.createObject unavailable", true end

  local obj = worldEditorCppApi.createObject(classname)
  if not obj then return "failed to create class: " .. classname, true end
  obj = Sim.upcast(obj) or obj

  local isTs = (classname == "TSStatic") or (obj.isSubClassOf and obj:isSubClassOf("TSStatic"))
  if isTs then
    local shape = args.shape or args.shapeName or NO_MESH_SHAPE
    obj:setField("shapeName", 0, tostring(shape))
    if args.collisionType ~= nil then
      obj:setField("collisionType", 0, tostring(args.collisionType))
    else
      obj:setField("collisionType", 0, "Collision Mesh")
    end
    if args.decalType ~= nil then
      obj:setField("decalType", 0, tostring(args.decalType))
    else
      obj:setField("decalType", 0, "Collision Mesh")
    end
  end

  if type(args.fields) == "table" then
    for k, v in pairs(args.fields) do
      obj:setField(tostring(k), "0", tostring(v))
    end
  end
  if args.field ~= nil then
    obj:setField(tostring(args.field), tostring(args.index or "0"), tostring(args.value))
  end

  local name = args.name
  if not name or name == "" then
    name = Sim.getUniqueName and Sim.getUniqueName(classname) or (classname .. "_" .. tostring(Engine.getSystemTimeMS and Engine.getSystemTimeMS() or math.random(10000, 99999)))
  end
  obj:registerObject(name)

  if obj.setPosition then
    local p = args.pos
    local pos = (type(p) == "table" and vec3(p.x or p[1], p.y or p[2], p.z or p[3])) or defaultCreatePos()
    obj:setPosition(pos)
  end
  if obj.setScale and type(args.scale) == "table" then
    local s = args.scale
    obj:setScale(vec3(s.x or s[1] or 1, s.y or s[2] or 1, s.z or s[3] or 1))
  elseif obj.setScale and tonumber(args.scale) then
    local s = tonumber(args.scale)
    obj:setScale(vec3(s, s, s))
  end
  if tonumber(args.yaw) and obj.getPosition and obj.setTransform then
    local q = quatFromEuler(0, 0, math.rad(tonumber(args.yaw)))
    local mtx = MatrixF(true)
    mtx:setFromQuatF(QuatF(q.x, q.y, q.z, q.w))
    local pos = obj:getPosition()
    obj:setTransform(mtx)
    obj:setPosition(pos)
  end

  if obj.postApply then obj:postApply() end

  local parent = resolveParent(args)
  if not parent then
    obj:delete()
    return "no parent group (MissionGroup missing? open a level)", true
  end
  parent:addObject(obj)

  local id = obj:getID()
  editor.history:commitAction("CreateObject", {
    objectId = id,
    serializedData = "[" .. obj:serialize(true, -1) .. "]",
  }, createObjectUndo, createObjectRedo, true)
  if editor.selectObjects then
    editor.selectObjects({ id }, editor.SelectMode_New)
  elseif editor.selectObjectById then
    editor.selectObjectById(id)
  end
  editor.setDirty()

  return jsonEncode({
    id = id,
    name = objName(obj),
    class = obj:getClassName(),
    parentId = parent.getID and parent:getID() or nil,
    shapeName = isTs and obj:getField("shapeName", "0") or nil,
  }), false
end

-- Apply position/rotation/scale to one object, pushing undo-backed history actions
-- (SetObjectTransform for pos/rot, SetObjectScale for scale). Changes are applied here;
-- the enclosing transaction is ended with dontCallRedoNow so redo is not re-run.
local function applyTransformToObj(obj, spec, oha)
  local objId = obj:getID()
  local wantPos = spec.pos
  local wantRot = spec.rot or spec.euler or spec.rotation

  if (wantPos or wantRot) and obj.setTransform and obj.setPosition then
    local oldTransform = editor.matrixToTable(obj:getTransform())
    local curPos = obj:getPosition()
    if wantRot then
      local qx, qy, qz, qw
      local r = spec.rot
      if type(r) == "table" and (r.w ~= nil or r[4] ~= nil) then
        qx, qy, qz, qw = r.x or r[1], r.y or r[2], r.z or r[3], r.w or r[4]
      else
        local e = spec.euler or spec.rotation or r
        local q = quatFromEuler(math.rad(e.x or e[1] or 0), math.rad(e.y or e[2] or 0), math.rad(e.z or e[3] or 0))
        qx, qy, qz, qw = q.x, q.y, q.z, q.w
      end
      local mtx = MatrixF(true)
      mtx:setFromQuatF(QuatF(qx, qy, qz, qw))
      obj:setTransform(mtx)
    end
    local p = wantPos
    local pos = (type(p) == "table" and vec3(p.x or p[1], p.y or p[2], p.z or p[3])) or curPos
    obj:setPosition(pos)
    editor.history:commitAction("SetObjectTransform",
      { objectId = objId, oldTransform = oldTransform, newTransform = editor.matrixToTable(obj:getTransform()) },
      oha.setObjectTransformUndo, oha.setObjectTransformRedo, true)
  end

  if spec.scale ~= nil and obj.setScale then
    local oldScale = obj:getScale()
    local s = spec.scale
    local newScale = (type(s) == "table" and vec3(s.x or s[1] or 1, s.y or s[2] or 1, s.z or s[3] or 1))
      or vec3(tonumber(s) or 1, tonumber(s) or 1, tonumber(s) or 1)
    obj:setScale(newScale)
    editor.history:commitAction("SetObjectScale",
      { objectId = objId, oldScale = oldScale, newScale = newScale },
      oha.setObjectScaleUndo, oha.setObjectScaleRedo, true)
  end
end

-- Set position/rotation/scale on scene object(s), undo-backed as one history transaction.
-- Target either a per-object 'items' list (each {id|name, pos?, euler?/rot?, scale?}) or a shared
-- transform (pos/euler/rot/scale) applied to 'ids'/'id'/'name' or the current selection.
function M.set_editor_transform(args)
  local err, isErr = requireEditor(true)
  if err then return err, isErr end
  args = args or {}
  local oha = require("editor/api/objectHistoryActions")()

  local work = {}
  if type(args.items) == "table" and #args.items > 0 then
    for _, it in ipairs(args.items) do
      local obj = (it.id and scenetree.findObjectById(tonumber(it.id))) or (it.name and scenetree.findObject(it.name))
      if obj then work[#work + 1] = { obj = obj, spec = it } end
    end
  else
    if args.pos == nil and args.rot == nil and args.euler == nil and args.rotation == nil and args.scale == nil then
      return "provide at least one of pos, euler/rot, scale (or an 'items' list)", true
    end
    local ids = resolveIds(args)
    if #ids == 0 then ids = (editor.getObjectSelection and editor.getObjectSelection()) or {} end
    if #ids == 0 then return "provide 'items', 'ids'/'id'/'name', or select objects first", true end
    local spec = { pos = args.pos, rot = args.rot, euler = args.euler, rotation = args.rotation, scale = args.scale }
    for _, id in ipairs(ids) do
      local obj = scenetree.findObjectById(tonumber(id))
      if obj then work[#work + 1] = { obj = obj, spec = spec } end
    end
  end
  if #work == 0 then return "no matching objects", true end

  editor.history:beginTransaction("SetObjectTransform")
  local ids = {}
  for _, w in ipairs(work) do
    applyTransformToObj(w.obj, w.spec, oha)
    ids[#ids + 1] = w.obj:getID()
  end
  editor.history:endTransaction(true) -- transforms already applied above
  editor.setDirty()

  return jsonEncode({ count = #ids, ids = ids }), false
end

M.schemas = {
  editor_status = {
    description = "World Editor status JSON: active, initialized, dirty, levelName/path, editMode, selectionCount, undoCount, redoCount, headless.",
  },
  set_editor_active = {
    description = "Activate or deactivate the World Editor (loads editor_main if needed). Activation is async over a couple frames; poll editor_status.",
    inputSchema = { type = "object", properties = {
      active = { type = "boolean", description = "true to open editor, false to close" },
      safeMode = { type = "boolean", description = "Load only safe-mode editor extensions" },
    }, required = { "active" } },
  },
  get_editor_selection = {
    description = "List currently selected scene objects as JSON: {count, objects:[{id,name,class}]}. Editor must be active.",
  },
  select_editor_objects = {
    description = "Select scene object(s) in the World Editor by id, ids[], or name. mode: 'new' (default), 'add', 'remove', 'toggle'.",
    inputSchema = { type = "object", properties = {
      id = { type = "integer", description = "Single object id" },
      ids = { type = "array", items = { type = "integer" }, description = "Multiple object ids" },
      name = { type = "string", description = "Exact object name" },
      mode = { type = "string", description = "new|add|remove|toggle (default new)" },
    } },
  },
  clear_editor_selection = { description = "Clear the World Editor object selection." },
  delete_editor_selection = {
    description = "Delete currently selected objects (editor history / undoable). Editor must be active.",
  },
  editor_undo = {
    description = "Undo World Editor history steps (default 1).",
    inputSchema = { type = "object", properties = {
      steps = { type = "integer", description = "How many undo steps (default 1)" },
    } },
  },
  editor_redo = {
    description = "Redo World Editor history steps (default 1).",
    inputSchema = { type = "object", properties = {
      steps = { type = "integer", description = "How many redo steps (default 1)" },
    } },
  },
  list_edit_modes = {
    description = "List registered World Editor edit mode names and the current mode.",
  },
  set_edit_mode = {
    description = "Switch World Editor edit mode by name (from list_edit_modes), e.g. objectSelect, createObject, terrainEditor.",
    inputSchema = { type = "object", properties = {
      name = { type = "string", description = "Edit mode key" },
    }, required = { "name" } },
  },
  fit_view_to_selection = {
    description = "Fit/frame the editor camera on the current object selection.",
  },
  editor_load_level = {
    description = "Open a level in the World Editor via editor.openLevel (discards unsaved editor changes; async). Provide name (from list_levels) or path (level folder / main file). Editor must be active.",
    inputSchema = { type = "object", properties = {
      name = { type = "string", description = "Level name (levelName from list_levels)" },
      path = { type = "string", description = "Level folder or main/mis file path" },
    } },
  },
  editor_save_level = {
    description = "Save the current level (MissionGroup serialize). Editor must be active and a level must be open. Disruptive if misused.",
  },
  list_editor_classes = {
    description = "List SimObject-derived class names creatable in the World Editor (optional 'pattern' substring filter). Use with create_editor_object.",
    inputSchema = { type = "object", properties = {
      pattern = { type = "string", description = "Case-insensitive substring filter (e.g. 'Light', 'TS', 'BeamNG')" },
    } },
  },
  set_editor_transform = {
    description = "Set position/rotation/scale on scene object(s) with undo (one history transaction; sets dirty). Target per-object with 'items' [{id|name, pos?, euler?/rot?, scale?}], or apply a shared pos/euler/rot/scale to 'ids'/'id'/'name' or the current selection. Rotation is euler {x,y,z} degrees or a quaternion rot {x,y,z,w}. scale is a number or {x,y,z}. Only provided components change.",
    inputSchema = { type = "object", properties = {
      items = { type = "array", description = "Per-object transforms: [{id|name, pos?, euler?/rot?, scale?}]", items = { type = "object" } },
      id = { type = "integer", description = "Single object id (shared-transform mode)" },
      ids = { type = "array", items = { type = "integer" }, description = "Object ids (shared-transform mode)" },
      name = { type = "string", description = "Object name (shared-transform mode)" },
      pos = { type = "object", description = "{x,y,z} world position" },
      euler = { type = "object", description = "{x,y,z} rotation in degrees" },
      rot = { type = "object", description = "{x,y,z,w} quaternion (overrides euler)" },
      scale = { description = "Uniform number or {x,y,z}" },
    } },
  },
  create_editor_object = {
    description = "Create a scene object in the World Editor (undoable, selected, dirty). class defaults to TSStatic. For TSStatic pass shape/shapeName (mesh .dae path); otherwise uses the editor no-mesh placeholder. Optional pos {x,y,z} (default: 10m in front of camera), scale, yaw (deg), name, parent/parentId, fields map, collisionType.",
    inputSchema = { type = "object", properties = {
      class = { type = "string", description = "SimObject class name (default TSStatic). Examples: TSStatic, PointLight, SpotLight, SimGroup, SpawnSphere, BeamNGTrigger" },
      classname = { type = "string", description = "Alias for class" },
      shape = { type = "string", description = "TSStatic mesh path (shapeName), e.g. /levels/.../myMesh.dae" },
      shapeName = { type = "string", description = "Alias for shape" },
      name = { type = "string", description = "Object name (auto-generated if omitted)" },
      pos = { type = "object", description = "{x,y,z} world position (default: in front of camera)" },
      scale = { description = "Uniform number or {x,y,z}" },
      yaw = { type = "number", description = "Yaw around Z in degrees" },
      parent = { type = "string", description = "Parent SimGroup name (default: selected parent or MissionGroup)" },
      parentId = { type = "integer", description = "Parent SimGroup id" },
      fields = { type = "object", description = "Extra field map {fieldName = value} set before register" },
      field = { type = "string", description = "Single extra field name" },
      value = { description = "Value for 'field'" },
      collisionType = { type = "string", description = "TSStatic collisionType (default 'Collision Mesh')" },
      decalType = { type = "string", description = "TSStatic decalType (default 'Collision Mesh')" },
    } },
  },
}

return M
