-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Scenetree tools: find objects (by class/name) and inspect their fields (like the editor inspector).

local M = {}

local function objName(obj)
  return (obj.getName and obj:getName()) or obj:getField("name", "0")
end

local function resolveObj(args)
  if args and args.id then return scenetree.findObjectById(tonumber(args.id)) end
  if args and args.name then return scenetree.findObject(args.name) end
  return nil
end

-- Find scene objects by class (optionally filtered by a name substring) or by exact name.
function M.find_objects(args)
  args = args or {}
  local out = {}
  local function add(obj)
    if obj then out[#out + 1] = { id = obj:getID(), name = objName(obj), class = obj:getClassName() } end
  end
  if args.name then
    add(scenetree.findObject(args.name))
  elseif args.class then
    local pat = args.pattern and tostring(args.pattern):lower()
    for _, n in ipairs(scenetree.findClassObjects(args.class) or {}) do
      if not pat or tostring(n):lower():find(pat, 1, true) then
        add(scenetree.findObject(n))
        if #out >= 500 then break end
      end
    end
  else
    return "provide 'class' (e.g. 'TSStatic', 'PointLight', 'BeamNGVehicle', 'SimGroup') or 'name'", true
  end
  return jsonEncode({ count = #out, objects = out }), false
end

-- Inspect a scene object (by id or name): class, name, static fields (with values), dynamic fields, position.
function M.get_object(args)
  local obj = resolveObj(args)
  if not obj then return "object not found (pass id or name)", true end
  local fields = {}
  for name in pairs(obj:getFields() or {}) do
    local v = obj:getField(name, "0")
    if v ~= nil and v ~= "" then fields[name] = v end
  end
  local dyn = {}
  for _, name in ipairs(obj:getDynamicFields() or {}) do
    dyn[name] = obj:getField(name, "0")
  end
  local out = {
    id = obj:getID(),
    name = objName(obj),
    class = obj:getClassName(),
    fields = fields,
  }
  if next(dyn) then out.dynamicFields = dyn end
  if obj.getPosition then
    local p = obj:getPosition()
    if p then out.position = { x = p.x, y = p.y, z = p.z } end
  end
  return jsonEncode(out), false
end

-- Update one or more fields on a scene object (the write counterpart of get_object).
function M.set_object_field(args)
  args = args or {}
  local obj = resolveObj(args)
  if not obj then return "object not found (pass id or name)", true end
  local set = {}
  if type(args.fields) == "table" then for k, v in pairs(args.fields) do set[k] = v end end
  if args.field ~= nil then set[tostring(args.field)] = args.value end
  if next(set) == nil then return "provide 'field'+'value' or a 'fields' map", true end
  local idx = tostring(args.index or "0")
  local names = {}
  for name, v in pairs(set) do obj:setField(name, idx, tostring(v)); names[#names + 1] = name end
  if obj.postApply then obj:postApply() end -- re-apply so changes take effect (mirrors the inspector)
  return string.format("set [%s] on %s [%s]", table.concat(names, ", "), objName(obj), obj:getClassName()), false
end

-- Delete a scene object (by id or name).
function M.delete_object(args)
  local obj = resolveObj(args)
  if not obj then return "object not found (pass id or name)", true end
  local desc = string.format("%s [%s] id %s", objName(obj), obj:getClassName(), tostring(obj:getID()))
  obj:deleteObject()
  return "deleted " .. desc, false
end

-- Serialize a scene object to JSON (full state, as written to a level/prefab file).
function M.serialize_object(args)
  local obj = resolveObj(args)
  if not obj then return "object not found (pass id or name)", true end
  return obj:serialize(args and args.pretty ~= false, 0), false
end

-- type mask for a filter keyword, or (broadMask, classFilter) for an arbitrary class name.
local function maskForClass(class)
  local kw = { vehicles = SOTVehicle, static = SOTStaticShape, item = SOTItem, player = SOTPlayer, terrain = SOTTerrain, water = SOTWater }
  if not class then return SOTVehicle end
  if kw[class] then return kw[class] end
  -- arbitrary class name: query everything, filter the (already frustum-culled) results by class
  return bit.bor(SOTVehicle, SOTStaticShape, SOTItem, SOTPlayer, SOTTerrain, SOTWater), class
end

-- Objects in the camera view via the native frustum query (sceneGetVisibleObjectIds: broad-phase
-- container query by type mask + exact OOBB cull in C++). Filter by 'vehicles' (default), a mask
-- keyword (static/item/player/terrain/water), an arbitrary class name, or a raw 'mask'.
function M.view_objects(args)
  args = args or {}
  if type(sceneGetVisibleObjectIds) ~= "function" then return "sceneGetVisibleObjectIds unavailable (rebuild the engine)", true end
  local mask, classFilter = tonumber(args.mask)
  if not mask then mask, classFilter = maskForClass(args.class) end
  local camPos = core_camera and core_camera.getPosition()
  local maxDist = tonumber(args.maxDist) or 1000
  local out = {}
  for _, id in ipairs(sceneGetVisibleObjectIds(mask)) do
    local o = scenetree.findObjectById(id)
    if o and (not classFilter or o:getClassName() == classFilter) then
      local d, pos = 0, nil
      if o.getPosition then local p = o:getPosition(); pos = { x = p.x, y = p.y, z = p.z }; if camPos then d = (p - camPos):length() end end
      if d <= maxDist then
        local e = { id = id, name = objName(o), class = o:getClassName(), dist = d, pos = pos }
        if o.getJBeamFilename then e.jbeam = o:getJBeamFilename() end
        out[#out + 1] = e
      end
    end
  end
  table.sort(out, function(a, b) return a.dist < b.dist end)
  while #out > 500 do table.remove(out) end
  return jsonEncode({ count = #out, objects = out }), false
end

-- Raycast. Default: from the camera along its forward (what the camera looks at). Or pass from/to, or from/dir/length.
function M.raycast(args)
  args = args or {}
  local function v(t) return t and vec3(t.x or t[1], t.y or t[2], t.z or t[3]) end
  local from = v(args.from) or (core_camera and core_camera.getPosition())
  if not from then return "provide 'from' {x,y,z} (no camera available)", true end
  local to = v(args.to)
  if not to then
    local dir = v(args.dir) or (core_camera and core_camera.getForward())
    if not dir then return "provide 'to' or 'dir' {x,y,z}", true end
    to = from + dir:normalized() * (tonumber(args.length) or 1000)
  end
  local res = castRay(from, to, args.includeTerrain ~= false, args.renderGeometry == true)
  if not res then
    return jsonEncode({ hit = false, from = { x = from.x, y = from.y, z = from.z }, to = { x = to.x, y = to.y, z = to.z } }), false
  end
  local out = { hit = true, pt = { x = res.pt.x, y = res.pt.y, z = res.pt.z }, norm = { x = res.norm.x, y = res.norm.y, z = res.norm.z } }
  for k, val in pairs(res) do
    local t = type(val)
    if t == "number" or t == "string" or t == "boolean" then out[k] = val end
  end
  return jsonEncode(out), false
end

M.schemas = {
  find_objects = {
    description = "Find scene objects in the scenetree. Pass 'class' to list all objects of a class (e.g. TSStatic, PointLight, BeamNGVehicle, SimGroup, Forest), optionally filtered by 'pattern' (name substring), or 'name' for an exact lookup. Returns [{id, name, class}].",
    inputSchema = { type = "object", properties = {
      class = { type = "string", description = "Class name to enumerate" },
      pattern = { type = "string", description = "Case-insensitive name substring filter (with class)" },
      name = { type = "string", description = "Exact object name to look up" },
    } },
  },
  get_object = {
    description = "Inspect a scene object (like the editor inspector): class, name, static fields with values, dynamic fields, and position. Identify it by id or name.",
    inputSchema = { type = "object", properties = {
      id = { type = "integer", description = "Object id" },
      name = { type = "string", description = "Object name" },
    } },
  },
  set_object_field = {
    description = "Set field(s) on a scene object (write counterpart of get_object); calls postApply so changes take effect. Values are strings (e.g. position '1 2 3'). Identify by id or name.",
    inputSchema = { type = "object", properties = {
      id = { type = "integer", description = "Object id" },
      name = { type = "string", description = "Object name" },
      field = { type = "string", description = "Single field name" },
      value = { description = "Value for 'field' (string-coerced)" },
      fields = { type = "object", description = "Map of {fieldName = value} to set multiple at once" },
      index = { type = "string", description = "Array index for array fields (default '0')" },
    } },
  },
  delete_object = {
    description = "Delete a scene object (by id or name). Permanent for this session.",
    inputSchema = { type = "object", properties = {
      id = { type = "integer", description = "Object id" },
      name = { type = "string", description = "Object name" },
    } },
  },
  serialize_object = {
    description = "Serialize a scene object to JSON (full state, as written to a level/prefab file). Identify by id or name.",
    inputSchema = { type = "object", properties = {
      id = { type = "integer", description = "Object id" },
      name = { type = "string", description = "Object name" },
      pretty = { type = "boolean", description = "Pretty-print (default true)" },
    } },
  },
  view_objects = {
    description = "List objects in the camera view via the native frustum query (fast: C++ broad-phase by type mask + exact OOBB cull), sorted by distance. Filter with class: a mask keyword ('vehicles' (default), 'static', 'item', 'player', 'terrain', 'water') or any exact scene class name (e.g. 'TSStatic', 'PointLight'); or pass a raw 'mask'. Returns [{id, name, class, dist, pos, jbeam?}].",
    inputSchema = { type = "object", properties = {
      class = { type = "string", description = "Mask keyword or exact class name (default 'vehicles')" },
      mask = { type = "integer", description = "Raw scene-object type mask (overrides class)" },
      maxDist = { type = "number", description = "Max distance in meters (default 1000)" },
    } },
  },
  raycast = {
    description = "Cast a ray and return the first hit (pt, norm, distance, hit object, material if any). Default: from the camera along its view direction (what you're looking at). Or pass from + to, or from + dir + length.",
    inputSchema = { type = "object", properties = {
      from = { type = "object", description = "{x,y,z} start (default: camera position)" },
      to = { type = "object", description = "{x,y,z} end point" },
      dir = { type = "object", description = "{x,y,z} direction (used with length if 'to' omitted; default: camera forward)" },
      length = { type = "number", description = "Ray length when using dir (default 1000)" },
      includeTerrain = { type = "boolean", description = "Hit terrain (default true)" },
      renderGeometry = { type = "boolean", description = "Hit render meshes too (default false)" },
    } },
  },
}

return M
