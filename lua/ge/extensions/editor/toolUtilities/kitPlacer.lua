-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared kit-instance placer.

local M = {}

-- Module dependencies.
local siteLights = require('editor/toolUtilities/siteLights')
local scatter = require('editor/toolUtilities/foliageScatter')

-- Module constants.
local sqrt = math.sqrt
local unitScale = vec3(1, 1, 1)
local FOREST_ENTRY_MAX = 1.08 -- under the 1.1 a forest file allows a matrix entry, with room for its float rounding

-- Module state.
local rot = quat()
local vAcross, vUp = vec3(), vec3()
local pose, vCol = MatrixF(true), vec3() -- scratch for the forest path below; createNewItem copies what it is handed
local liveForest, liveFd = nil, nil
local liveEntries = setmetatable({}, { __mode = 'k' }) -- every live forest piece any tool holds, for the save lift
local held = nil -- what the save lift took out, until relayLive puts it back


-- Piece scale, in the shape's own X=along / Y=across / Z=up frame: a number scales uniformly, a {x,y,z} table fits a piece
-- to a slot it cannot reach by uniform scale alone (an arch stretched to its bay while keeping a fixed springing height).
local function scaleVec(scl)
  if type(scl) == 'table' then return vec3(scl.x, scl.y, scl.z) end
  if scl and scl ~= 1 then return vec3(scl, scl, scl) end
  return unitScale
end

-- One kit piece's DAE, or nil if it has not been baked. Every kit names its pieces its own way, so the path is worked out
-- by whichever kit owns it and only checked here; the path says which kit and which piece well enough to report.
local shapeSeen, shapeWarned = {}, {}
local function shapeOf(path)
  if not path then return nil end
  if shapeSeen[path] then return path end
  if FS and not FS:fileExists(path) then
    if not shapeWarned[path] then
      shapeWarned[path] = true
      log('E', 'kitPlacer', 'kit piece is not baked: ' .. path)
    end
    return nil
  end
  shapeSeen[path] = true
  return path
end

-- The level's forest data, or nil on a level with none. Asked again only once the forest it had is gone, with the level.
-- `create` makes one where the level has none, as planting does: falling back to TSStatics put a town's worth of them in
-- the scene. Only for planting, so nothing taking pieces down while a level unloads stands a new forest in it.
local function forestData(create)
  if not (liveForest and simObjectExists(liveForest)) then
    liveForest = create and scatter.ensureForest() or (core_forest and core_forest.getForestObject())
    liveFd = liveForest and liveForest:getData()
  end
  return liveFd
end

local function scaleXYZ(scl)
  if type(scl) == 'table' then return scl.x, scl.y, scl.z end
  scl = scl or 1
  return scl, scl, scl
end

-- Create one TSStatic piece for `shapePath` under `folder`, at pos + quaternion.
local function makeTs(folder, shapePath, name, collidable, px, py, pz, qx, qy, qz, qw, scl)
  local existing = name and scenetree.findObject(name)
  if existing and simObjectExists(existing) then existing:delete() end
  -- Every kit piece in every tool is stamped here, so one check covers the lot. After the stale piece goes, or a rebuild
  -- that has lost its kit would leave the last one standing.
  if not shapeOf(shapePath) then return nil end
  local mesh = createObject('TSStatic')
  if not mesh then return nil end
  mesh:setField('shapeName', 0, shapePath)
  mesh:setField('collisionType', 0, collidable and 'Collision Mesh' or 'None')
  mesh.canSave = false -- transient preview: a level save writes nothing until this piece is burned (canSave flipped true).
  if name then mesh:registerObject(name) else mesh:registerObject('') end
  mesh.scale = scaleVec(scl)
  if folder and folder.addObject then folder:addObject(mesh.obj) end
  mesh:setPosRot(px, py, pz, qx, qy, qz, qw)
  return mesh
end

-- Names a piece for its owner. Numbered off a running count rather than off the piece's place in the run, because a
-- rebuild that reuses what it can leaves pieces standing under the names their last run gave them: a new piece named for
-- where it now sits could pick the name of one of those and take a piece still in use down with it.
local made = 0
local function pieceName(sink)
  made = made + 1
  return (sink.ownerId or 'kit') .. '_' .. made
end

-- Build a sink for `ownerId`. A nil owner makes unnamed pieces, for a caller that never finds them by name.
local function newSink(folder, ownerId, collidable, list)
  return { folder = folder, ownerId = ownerId, collidable = collidable == true, list = list or {}, n = 0 }
end

-- ============================ Reuse across rebuilds =========================
-- A tool rebuilds its whole kit whenever anything on it moves, and while a handle is dragged that is every frame. Made
-- again from nothing, a site of a few thousand pieces spends the frame deleting and recreating scene objects that end up
-- exactly where they already were. So the last run's pieces are set aside and the next one draws from them.
--
-- Set aside in a queue per shape, and handed back in the order they went in. A rebuild that changed nothing asks for the
-- same shapes in the same order and so gets each piece back where it already was, for no work at all. One that laid a few
-- more posts around a court it resized only shifts the queue for that one shape, and everything else still comes back
-- standing right -- where matching the two runs off position alone would have thrown away everything downstream of the
-- court and built it again.
--
-- Keyed on the LIST and not the sink, since several sinks share one list and fill it one after another.
local pools = setmetatable({}, { __mode = 'k' })

-- Whatever the run did not ask for, taken away: what is left in the queues is what the last run had and this one has no
-- use for. Answers how many went.
local function endReuse(list)
  local byShape = list and pools[list]
  if not byShape then return 0 end
  pools[list] = nil
  local gone = 0
  for _, q in pairs(byShape) do
    for i = q.head, #q do
      local e = q[i]
      if e.obj and simObjectExists(e.obj) then e.obj:delete(); gone = gone + 1 end
    end
  end
  return gone
end

-- Set the last run's pieces aside for the next one. The list is emptied but nothing is deleted.
local function beginReuse(list)
  if not list then return end
  endReuse(list) -- a run that threw part way through left pieces set aside, and they are stale now
  local byShape = {}
  for i = 1, #list do
    local e = list[i]
    -- No object means the shape was never baked and nothing was made, so there is nothing to keep.
    if e and e.obj and simObjectExists(e.obj) then
      local q = byShape[e.shape]
      if not q then q = { head = 1 }; byShape[e.shape] = q end
      q[#q + 1] = e
    end
  end
  table.clear(list)
  pools[list] = byShape
end

-- The next piece of this shape left over from the last run, if there is one.
local function takeHeld(list, shapePath)
  local byShape = pools[list]
  local q = byShape and shapePath and byShape[shapePath]
  if not q then return nil end
  local e = q[q.head]
  if not e then return nil end
  q.head = q.head + 1
  if not simObjectExists(e.obj) then return nil end -- deleted from under us, by the scene tree or by hand
  return e
end

-- Place one instance (pos + quaternion) and append its entry to the sink's flat list. A missing shape / no folder yields a
-- nil-obj entry (kept so the count stays honest; simply nothing to render or delete).
local function placeTs(sink, shapePath, px, py, pz, qx, qy, qz, qw, scl)
  sink.n = sink.n + 1
  local list = sink.list
  local s = scaleVec(scl)
  local sx, sy, sz = s.x, s.y, s.z
  local held = takeHeld(list, shapePath)
  if held then
    -- Standing where it is wanted already, which is what most of a site is while one thing on it is dragged. Writing the
    -- same transform back would be thousands of calls a frame for nothing on screen.
    if held.px ~= px or held.py ~= py or held.pz ~= pz or held.qx ~= qx or held.qy ~= qy or held.qz ~= qz
       or held.qw ~= qw or held.sx ~= sx or held.sy ~= sy or held.sz ~= sz then
      held.obj.scale = s
      held.obj:setPosRot(px, py, pz, qx, qy, qz, qw)
      held.px, held.py, held.pz, held.qx, held.qy, held.qz, held.qw = px, py, pz, qx, qy, qz, qw
      held.sx, held.sy, held.sz = sx, sy, sz
    end
    list[#list + 1] = held
    return
  end
  local mesh
  if shapePath and sink.folder then
    mesh = makeTs(sink.folder, shapePath, sink.ownerId and pieceName(sink), sink.collidable, px, py, pz, qx, qy, qz, qw, scl)
  end
  list[#list + 1] = { obj = mesh, shape = shapePath, px = px, py = py, pz = pz,
                      qx = qx, qy = qy, qz = qz, qw = qw, sx = sx, sy = sy, sz = sz }
end

-- The rotation of a local frame: local X -> along (a), local Z -> up (u), local Y -> up x along.
local function frameRot(ax, ay, az, ux, uy, uz)
  local cx = uy * az - uz * ay
  local cy = uz * ax - ux * az
  local cz = ux * ay - uy * ax
  local cl = sqrt(cx * cx + cy * cy + cz * cz)
  if cl > 1e-9 then cx, cy, cz = cx / cl, cy / cl, cz / cl end
  vAcross:set(cx, cy, cz)
  vUp:set(ux, uy, uz)
  rot:setFromDir(vAcross, vUp)
  return rot
end

-- A forest item's pose for a rotation, scale and position: the TSStatic's own matrix with the scale baked into its columns,
-- since the forest has no per-axis scale. The columns are the unit axes turned the way mathlib's quat * vec3 turns them.
local function framePose(x, y, z, w, sx, sy, sz, ox, oy, oz)
  vCol:set((1 - 2 * (y * y + z * z)) * sx, 2 * (x * y - z * w) * sx, 2 * (x * z + y * w) * sx); pose:setColumn(0, vCol)
  vCol:set(2 * (x * y + z * w) * sy, (1 - 2 * (x * x + z * z)) * sy, 2 * (y * z - x * w) * sy); pose:setColumn(1, vCol)
  vCol:set(2 * (x * z - y * w) * sz, 2 * (y * z + x * w) * sz, (1 - 2 * (x * x + y * y)) * sz); pose:setColumn(2, vCol)
  vCol:set(ox, oy, oz); pose:setPosition(vCol)
  return pose
end

local function colLen(m, i)
  local c = m:getColumn(i)
  return sqrt(c.x * c.x + c.y * c.y + c.z * c.z)
end

-- Plant `data` at matrix `m` times `scl`. The forest file keeps an item's scale apart from its matrix, and on load resets a
-- matrix it takes for broken - any entry over 1.1, or in a non-shipping build a first column not of unit length - which
-- leaves a scaled or stretched piece unturned at full size. So the matrix is divided down until both hold where the stretch
-- allows, the first holding always, and what was divided out goes in the item's scale: the same pose, and one that loads.
local function newItem(fd, data, m, scl)
  scl = scl or 1
  local a, b, c = colLen(m, 0), colLen(m, 1), colLen(m, 2)
  local s = math.max(a, math.max(a, b, c) / FOREST_ENTRY_MAX)
  if s > 1e-6 and math.abs(s - 1) > 1e-5 then
    local k = 1 / s
    for i = 0, 2 do
      local col = m:getColumn(i)
      vCol:set(col.x * k, col.y * k, col.z * k)
      m:setColumn(i, vCol)
    end
    scl = scl * s
  end
  return fd:createNewItem(data, m, scl)
end

-- Place one kit piece by a local frame. A sink carrying `emitFrame` takes the frame itself instead of a scene object, which
-- is what a tool that bakes its output rather than spawning it wants.
local function placeOriented(sink, shapePath, ox, oy, oz, ax, ay, az, ux, uy, uz, scl)
  if sink.emitFrame then
    sink.n = sink.n + 1
    return sink.emitFrame(shapePath, ox, oy, oz, ax, ay, az, ux, uy, uz, scl)
  end
  local q = frameRot(ax, ay, az, ux, uy, uz)
  placeTs(sink, shapePath, ox, oy, oz, q.x, q.y, q.z, q.w, scl)
end

-- One piece on its own, outside any sink, for a caller keeping its own slots.
local function spawnOriented(folder, shapePath, name, collidable, ox, oy, oz, ax, ay, az, ux, uy, uz, scl)
  if not (shapePath and folder) then return nil end
  local q = frameRot(ax, ay, az, ux, uy, uz)
  return makeTs(folder, shapePath, name, collidable, ox, oy, oz, q.x, q.y, q.z, q.w, scl)
end

-- Move a piece already in the scene onto a new frame. Far cheaper than deleting one and building another, which is what
-- makes it worth telling a piece that moved from a piece that changed.
local function moveOriented(entry, ox, oy, oz, ax, ay, az, ux, uy, uz, scl)
  local it = entry and entry.item
  if it then
    local fd = forestData()
    if not fd then return false end
    -- updateItem is the forest's own move, and costs more than taking the item out and planting it again.
    fd:removeItem(it)
    local sx, sy, sz = scaleXYZ(scl)
    local q = frameRot(ax, ay, az, ux, uy, uz)
    entry.item = newItem(fd, entry.data, framePose(q.x, q.y, q.z, q.w, sx, sy, sz, ox, oy, oz))
    return true
  end
  local o = entry and entry.obj
  if not (o and simObjectExists(o)) then return false end
  local q = frameRot(ax, ay, az, ux, uy, uz)
  -- Only when it changed: a move almost never rescales, and writing the scale costs more than the move does.
  local s = scaleVec(scl)
  if entry.sx ~= s.x or entry.sy ~= s.y or entry.sz ~= s.z then
    o.scale = s
    entry.sx, entry.sy, entry.sz = s.x, s.y, s.z
  end
  o:setPosRot(ox, oy, oz, q.x, q.y, q.z, q.w)
  return true
end

-- Clear a sink's placed pieces: delete each TSStatic, pull each forest item, and empty the list for reuse.
local function deleteList(list)
  if not list then return end
  endReuse(list) -- a run abandoned part way leaves pieces set aside, and those come down too
  local fd = nil
  for i = 1, #list do
    local entry = list[i]
    if type(entry) == 'table' then
      liveEntries[entry] = nil
      if entry.item then
        fd = fd or forestData()
        if fd then fd:removeItem(entry.item) end
        entry.item = nil
      elseif entry.obj and simObjectExists(entry.obj) then
        entry.obj:delete()
      end
    end
  end
  table.clear(list)
end

local function safeName(prefix, id)
  return prefix .. string.gsub(tostring(id), '[^%w]', '_')
end

-- ============================ Burn (persist) ================================
-- "Burn" commits an owner's transient pieces to the level (they save with it) -- the sidewalk analog of the road-DAE bake.
-- For TSStatics this just flips canSave=true; the CALLER stores the returned name manifest on its own serialized owner record
-- (like group.bakedManifest) and hands it back to removeBurned on rebuild.

-- Flip a sink's (or a bare { list = ... } wrapper's) pieces to persistent (canSave=true) and return their scene-object names
-- as the manifest. Does NOT delete or detach (the caller detaches its pool). Names survive save/reload (registerObject keeps
-- them), so removeBurned can find the pieces again by name after a level load.
local function commitSink(sink)
  local names = {}
  if not sink or not sink.list then return names end
  for i = 1, #sink.list do
    local entry = sink.list[i]
    local o = entry and entry.obj
    if o and simObjectExists(o) then
      o.canSave = true
      -- A sink that asked for collision gets it here rather than while it was transient: the static collision world is only
      -- rebuilt on demand, so a piece that moved or went away as a preview would leave its hull standing.
      if sink.collidable then o:setField('collisionType', 0, 'Collision Mesh') end
      local nm = o.getName and o:getName()
      if nm and nm ~= '' then names[#names + 1] = tostring(nm) end
    end
  end
  if editor and editor.setDirty then editor.setDirty() end
  return names
end

-- Remove every burned piece recorded in `nameManifest` (from commitSink) by name. Returns the count removed. A nil/empty
-- manifest is a no-op.
local function removeBurned(nameManifest)
  if not nameManifest or #nameManifest == 0 then return 0 end
  local removed = 0
  for i = 1, #nameManifest do
    local o = scenetree.findObject(nameManifest[i])
    if o and simObjectExists(o) then o:delete(); removed = removed + 1 end
  end
  if removed > 0 and editor and editor.setDirty then editor.setDirty() end
  return removed
end

-- ============================ Forest items ==================================
-- What a piece becomes: a burned one always, a live one wherever a forest is to hand. A forest item is a transform and a
-- pointer to a datablock, where a TSStatic is a scene object with a name, a field table and a place in the update tree -
-- so a street's worth of kit costs the level orders of magnitude less as forest than as statics, and every other object
-- in the scene is cheaper to reach without a hundred thousand pieces in front of it. Everything a kit frame carries makes
-- the trip: the forest keeps the whole pose matrix, so a piece stretched to fit its slot arrives stretched. The one thing
-- that does not is a per-instance colour, which a lit window's glow needs and the forest has no slot for, so the lit few
-- stay TSStatics.
--
-- Collision comes along with the shape: most kit pieces bake a Colmesh, and a forest item collides against it unless its
-- datablock's `collidable` is off. Read when the collision world is rebuilt, which lands a frame after be:reloadCollision.
-- A burned piece keeps it, as it always has. A live piece gets a datablock of its own, named apart so it is never written
-- with the level's: with collision off where it stands in for a TSStatic with none, on where its TSStatic collided.

local MASSING_ITEM_PREFIX = 'massingKit_'
local PREFIX = { burned = MASSING_ITEM_PREFIX, live = 'liveKit_', solid = 'liveSolid_' }
local datas = { burned = {}, live = {}, solid = {} } -- shape path -> ForestItemData, so a street shares one per shape

-- A datablock name for a shape path. It is an object identifier, so letters, digits and underscores only, and it is
-- built from the WHOLE path rather than the file's own name because two kits can each hold a course_stone.dae.
local function itemDataName(shapePath, prefix)
  return prefix .. string.gsub(string.gsub(shapePath, '^/+', ''), '[^%w]', '_')
end

local function isLiveData(d)
  local nm = d and tostring(d.name or '')
  return nm ~= nil and (nm:sub(1, #PREFIX.live) == PREFIX.live or nm:sub(1, #PREFIX.solid) == PREFIX.solid)
end

-- The ForestItemData standing for one kit shape, made on first use: the level's own, or with `kind` 'live' / 'solid' a
-- tool's copy for its live pieces. Built the long way round rather than through editor.createDataBlock so it is
-- deliberately NOT handed to the persistence manager: writeItemDatas below serializes the level's into its
-- managedItemData.json itself, and letting the manager write them as well would add the __parent entry the hand-authored
-- entries do not carry. It still joins the datablock group, which holds the reference that keeps it alive.
local function itemDataFor(shapePath, kind)
  if not shapePath then return nil end
  kind = kind or 'burned'
  local cache = datas[kind]
  local got = cache[shapePath]
  if got and simObjectExists(got) then return got end
  local name = itemDataName(shapePath, PREFIX[kind])
  got = scenetree.findObject(name) -- a reload, or a level that already carries the datablock from an earlier save
  if not (got and simObjectExists(got)) then
    got = worldEditorCppApi and worldEditorCppApi.createObject('ForestItemData')
    if not got then return nil end
    got:registerObject('')
    local dbGroup = scenetree.findObject('dataBlockGroup')
    if dbGroup then dbGroup:addObject(got) end
    got:setName(name)
    Sim.getDataBlockSet():addObject(got)
    got:setInternalName(name)
    got:setField('shapeFile', 0, shapePath)
    got:setField('windScale', 0, '0')
    got:setField('dampingCoefficient', 0, '0')
    got:setField('annotation', 0, 'BUILDINGS')
    if kind == 'live' then got:setField('collidable', 0, '0') end
  end
  cache[shapePath] = got
  return got
end

-- One live piece by a local frame, as a forest item: the entry a list keeps for it, or nil with no forest to plant in or no
-- baked shape, for the caller to stand a TSStatic instead.
local function plantOriented(fd, shapePath, ox, oy, oz, ax, ay, az, ux, uy, uz, scl)
  if not (fd and shapeOf(shapePath)) then return nil end
  local data = itemDataFor(shapePath, 'live')
  if not data then return nil end
  local sx, sy, sz = scaleXYZ(scl)
  local q = frameRot(ax, ay, az, ux, uy, uz)
  local e = { item = newItem(fd, data, framePose(q.x, q.y, q.z, q.w, sx, sy, sz, ox, oy, oz)),
              data = data, shape = shapePath }
  liveEntries[e] = true
  return e
end

--- Pool slot `i` of `list` stood as a live forest item: `shapePath` at a position, quaternion and per-axis scale, `solid`
--- for a piece that collides as its TSStatic did. A slot whose shape and pose have not changed is left as it stands, which
--- is most of a run while one thing on it is dragged. A shape that is not baked keeps its slot with nothing in it.
local function poseLive(fd, list, i, shapePath, solid, px, py, pz, qx, qy, qz, qw, sx, sy, sz)
  local e = list[i]
  if e and (e.shape ~= shapePath or e.solid ~= solid) then
    if e.item then fd:removeItem(e.item) end
    liveEntries[e] = nil
    e = nil
  end
  if not e then
    e = { shape = shapePath, solid = solid, data = shapeOf(shapePath) and itemDataFor(shapePath, solid and 'solid' or 'live') }
    list[i] = e
    liveEntries[e] = true
  end
  if not e.data then return e end
  if e.item and e.px == px and e.py == py and e.pz == pz and e.qx == qx and e.qy == qy and e.qz == qz and e.qw == qw
     and e.sx == sx and e.sy == sy and e.sz == sz then return e end
  if e.item then fd:removeItem(e.item) end
  e.item = newItem(fd, e.data, framePose(qx, qy, qz, qw, sx, sy, sz, px, py, pz))
  e.px, e.py, e.pz, e.qx, e.qy, e.qz, e.qw, e.sx, e.sy, e.sz = px, py, pz, qx, qy, qz, qw, sx, sy, sz
  return e
end

--- Whether a pool slot is a live forest piece rather than a TSStatic.
local function isLive(e) return e ~= nil and liveEntries[e] ~= nil end

--- Slot `k` of `t` out of the forest and off the table. `fd` may be nil, for the forest the piece stands in.
local function dropLive(fd, t, k)
  local e = t[k]
  if not e then return end
  fd = fd or (e.item and forestData())
  if e.item and fd then fd:removeItem(e.item) end
  liveEntries[e] = nil
  t[k] = nil
end

--- Every slot of a pool past the first `n`, out of the forest and off the list.
local function trimLive(fd, list, n)
  for i = #list, n + 1, -1 do dropLive(fd, list, i) end
end

-- A live piece handed to the level: the same pose on the shape's own datablock, the one that collides. Nil for an entry
-- that is not a forest item.
local function burnItem(fd, entry)
  local it = entry and entry.item
  if not (fd and it) then return nil end
  local data = itemDataFor(entry.shape)
  if not data then return nil end
  local burned = newItem(fd, data, it:getTransform(), it:getScale())
  fd:removeItem(it)
  entry.item = nil
  liveEntries[entry] = nil
  return burned
end

--- Every live entry in a pool handed to the level, its item appended to `out`, and the pool emptied.
local function burnList(fd, list, out)
  for i = 1, #(list or {}) do
    local b = burnItem(fd, list[i])
    if b then out[#out + 1] = b end
    if list[i] then liveEntries[list[i]] = nil end
  end
  if list then table.clear(list) end
end

local function allItems(fd)
  local box = Box3F()
  box.minExtents = Point3F(-1e6, -1e6, -1e6)
  box.maxExtents = Point3F(1e6, 1e6, 1e6)
  return fd:getItemsBox(box) or {}
end

--- Every live piece out of the forest for a level save, which writes the forest as it finds it: every tool's, and any a
--- tool lost track of, which would otherwise go out with the level. For each tool to call from its own save hook; the
--- first does the work. `relayLive` puts back the ones still wanted.
local function liftLive()
  if held then return end
  local fd = forestData()
  if not fd then return end
  held = { fd = fd }
  for e in pairs(liveEntries) do
    if e.item then held[#held + 1] = { e, e.item, e.item:getTransform(), e.item:getScale() } end
  end
  for _, it in ipairs(allItems(fd)) do
    if isLiveData(it:getData()) then fd:removeItem(it) end
  end
end

--- For each tool to call every frame: the first after a save puts back what liftLive took out. Only into an entry still
--- holding what was lifted from it, since one moved or taken down since has moved on without it, and only into the forest
--- it came out of.
local function relayLive()
  if not held then return end
  local h0 = held
  held = nil
  if forestData() ~= h0.fd then return end
  for i = 1, #h0 do
    local h = h0[i]
    local e = h[1]
    if e.item == h[2] then e.item = newItem(h0.fd, e.data, h[3], h[4]) end
  end
end

-- Plant one piece straight from a TSStatic's own pose.
local function plantStatic(fd, obj)
  if not (fd and obj and simObjectExists(obj)) then return nil end
  local data = itemDataFor(obj:getField('shapeName', 0))
  if not data then return nil end
  local m, s = obj:getTransform(), obj.scale
  local c = m:getColumn(0); vCol:set(c.x * s.x, c.y * s.x, c.z * s.x); pose:setColumn(0, vCol)
  c = m:getColumn(1); vCol:set(c.x * s.y, c.y * s.y, c.z * s.y); pose:setColumn(1, vCol)
  c = m:getColumn(2); vCol:set(c.x * s.z, c.y * s.z, c.z * s.z); pose:setColumn(2, vCol)
  c = m:getColumn(3); vCol:set(c.x, c.y, c.z); pose:setPosition(vCol)
  return newItem(fd, data, pose)
end

-- Which of our datablocks something is actually standing on. A datablock outlives the pieces that needed it -- it is
-- cached and shared, so a burn that was undone leaves its own behind -- and a datablock loads its shape when the level
-- does, so writing those would cost a shape load every start for a piece that is not there.
local function itemDatasInUse()
  local forest = core_forest and core_forest.getForestObject()
  local fd = forest and forest:getData()
  if not fd then return nil end
  local used = {}
  for _, it in ipairs(allItems(fd)) do
    local d = it.getData and it:getData()
    local nm = d and tostring(d.name or '')
    if nm:sub(1, #MASSING_ITEM_PREFIX) == MASSING_ITEM_PREFIX then used[nm] = true end
  end
  return used
end

-- Write the kit datablocks into the level's managedItemData.json, for a tool to call on level save. The massingKit_
-- keys are rebuilt from what is standing, so newly burned shapes are added and ones nothing uses drop out; everything
-- else in the file belongs to the Forest Editor and is left exactly as it wrote it. Without this a burned building loads
-- next session with every piece pointing at a datablock that no longer exists.
local function writeItemDatas()
  local levelPath = (editor and editor.levelPath) or (path.split(getMissionFilename()))
  if not levelPath then return end
  local dbFile = levelPath .. 'art/forest/managedItemData.json'
  local data = jsonReadFile(dbFile) or {}
  local had = false
  for key in pairs(data) do
    if type(key) == 'string' and key:sub(1, #MASSING_ITEM_PREFIX) == MASSING_ITEM_PREFIX then
      data[key] = nil
      had = true
    end
  end
  local used = itemDatasInUse() or {}
  local live = {}
  for _, id in ipairs(scenetree.findClassObjects('ForestItemData') or {}) do
    local o = scenetree.findObject(id)
    local nm = o and tostring(o.name or '')
    if nm and used[nm] then live[#live + 1] = o end
  end
  if not had and #live == 0 then return end -- nothing of ours on this level, so the file is left untouched
  for i = 1, #live do
    local o = live[i]
    local nm = tostring(o.name)
    data[nm] = { name = nm, internalName = nm, class = o:getClassName(),
                 shapeFile = tostring(o.shapeFile), windScale = 0, dampingCoefficient = 0,
                 annotation = 'BUILDINGS' }
  end
  jsonWriteFile(dbFile, data, true)
end

-- Colour a lit piece. `night` hands it to core_environment's day/night pass as well, which drives the same instanceColor
-- to black by day and back to this at dusk - so a sign or a lamp lens is dark glass in daylight rather than burning
-- through it. The colour is still written here, so a piece reads right before the first refresh reaches it.
local function setGlow(obj, glow, night)
  if not (obj and glow and simObjectExists(obj)) then return end
  obj.useInstanceRenderData = true
  local r, g, b = glow[1] or 1, glow[2] or 1, glow[3] or 1
  obj:setField('instanceColor', 0, string.format('%f %f %f 1', r, g, b))
  if night then
    obj:setField('nightEmissive', 0, '1')
    obj:setField('nightEmissiveColor', 0, string.format('%f %f %f', r, g, b))
  end
  if obj.updateInstanceRenderData then obj:updateInstanceRenderData() end
  -- After the colour: the environment reads the lit colour off it as it registers it.
  if night then siteLights.markDirty(obj) end
end

-- For a tool whose burn is statics and nothing else, committing or reconciling one needs no more than the editor marked
-- dirty so the save is offered: the pieces are scene objects and go out with the level. A tool that plants forest items
-- instead has the datablocks to write as well, which is writeItemDatas above.
local function markDirty()
  if editor and editor.setDirty then editor.setDirty() end
end


-- Public interface.
M.MASSING_ITEM_PREFIX = MASSING_ITEM_PREFIX

M.shapeOf = shapeOf
M.newSink = newSink
M.placeTs = placeTs
M.placeOriented = placeOriented
M.spawnOriented = spawnOriented
M.moveOriented = moveOriented
M.setGlow = setGlow
M.deleteList = deleteList
M.beginReuse = beginReuse
M.endReuse = endReuse
M.safeName = safeName
M.commitSink = commitSink
M.removeBurned = removeBurned
M.itemDataFor = itemDataFor
M.liveForestData = function() return forestData(true) end
M.plantOriented = plantOriented
M.poseLive = poseLive
M.trimLive = trimLive
M.dropLive = dropLive
M.isLive = isLive
M.burnItem = burnItem
M.burnList = burnList
M.liftLive = liftLive
M.relayLive = relayLive
M.plantStatic = plantStatic
M.writeItemDatas = writeItemDatas
M.markDirty = markDirty

return M