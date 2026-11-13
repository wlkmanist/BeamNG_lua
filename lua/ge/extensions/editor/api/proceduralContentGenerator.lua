-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local editor

local identityQuat = quat(0, 0, 0, 1)

local function makeRng(seed)
  local s = tonumber(seed) or 1
  if s < 1 then s = 1 end
  s = math.floor(s) % 2147483647
  if s <= 0 then s = 1 end
  return function()
    s = (s * 48271) % 2147483647
    return (s - 1) / 2147483646
  end
end

local function toVec3(v, fallback)
  if v == nil then return fallback and vec3(fallback) or vec3(0, 0, 0) end
  if type(v) == "cdata" or (type(v) == "table" and v.toPoint3F) then return vec3(v) end
  if type(v) == "number" then return vec3(v, v, v) end
  return vec3(v.x or v[1] or 0, v.y or v[2] or 0, v.z or v[3] or 0)
end

local function toQuat(q)
  if q == nil then return quat(identityQuat) end
  if type(q) == "cdata" then return quat(q) end
  return quat(q.x or q[1] or 0, q.y or q[2] or 0, q.z or q[3] or 0, q.w or q[4] or 1)
end

local function rangeValue(rng, r)
  if r == nil then return nil end
  if type(r) == "number" then return r end
  local a = r.min or r[1] or 0
  local b = r.max or r[2] or a
  if b < a then a, b = b, a end
  return a + (b - a) * rng()
end

local function listIndex(list, randomness)
  if not list or #list == 0 then return nil, nil end
  local r = tonumber(randomness) or 0
  if r < 0 then r = 0 elseif r > 1 then r = 1 end
  local i = math.floor(r * #list) + 1
  if i > #list then i = #list end
  return i, list[i]
end

local function newPoint(opts)
  opts = opts or {}
  return {
    pos = toVec3(opts.pos),
    rot = toQuat(opts.rot),
    scale = toVec3(opts.scale, vec3(1, 1, 1)),
    bounds = toVec3(opts.bounds, vec3(1, 1, 1)),
    color = opts.color or { r = 1, g = 1, b = 1, a = 1 },
    spawnRandomness = tonumber(opts.spawnRandomness) or 0,
  }
end

local function copyPoint(p)
  local c = p.color or { r = 1, g = 1, b = 1, a = 1 }
  return {
    pos = vec3(p.pos),
    rot = quat(p.rot),
    scale = vec3(p.scale),
    bounds = vec3(p.bounds),
    color = { r = c.r or 1, g = c.g or 1, b = c.b or 1, a = c.a or 1 },
    spawnRandomness = tonumber(p.spawnRandomness) or 0,
  }
end

local function copyPoints(points)
  local out = {}
  for i = 1, #(points or {}) do
    out[i] = copyPoint(points[i])
  end
  return out
end

local function colorToString(c)
  c = c or {}
  return string.format("%g %g %g %g", c.r or 1, c.g or 1, c.b or 1, c.a or 1)
end

local function rotToString(q)
  return string.format("%g %g %g %g", q.x, q.y, q.z, q.w)
end

local function posToString(p)
  return string.format("%g %g %g", p.x, p.y, p.z)
end

local function scaleToString(s)
  return string.format("%g %g %g", s.x, s.y, s.z)
end

local function applyPosRotScale(obj, point)
  if obj.setPosRot then
    local q = point.rot or identityQuat
    obj:setPosRot(point.pos.x, point.pos.y, point.pos.z, q.x, q.y, q.z, q.w)
  elseif obj.setPosition then
    obj:setPosition(point.pos)
  end
  if obj.setScale then
    obj:setScale(point.scale or vec3(1, 1, 1))
  end
end

-------------------------------------------------------------------------------
-- Graph / nodes
-------------------------------------------------------------------------------

local Graph = {}
Graph.__index = Graph

local Pipe = {}
Pipe.__index = Pipe

local function newNode(kind, params, execute)
  return {
    kind = kind,
    params = params or {},
    execute = execute,
    inputs = {},
    outputs = {},
    incoming = {},
    outgoing = {},
  }
end

local function resolvePin(node, pinName)
  local link = node.incoming[pinName]
  if not link then
    return node.params[pinName]
  end
  local src = link.node
  if src.outputs then
    return src.outputs[link.pin]
  end
  return nil
end

function Graph:_addNode(node)
  self.nodes[#self.nodes + 1] = node
  node.id = #self.nodes
  node.graph = self
  return node
end

function Graph:connect(fromNode, fromPin, toNode, toPin)
  if fromNode.node then
    toPin = toNode
    toNode = fromPin
    fromPin = fromNode.pin
    fromNode = fromNode.node
  end
  toNode.incoming[toPin] = { node = fromNode, pin = fromPin }
  fromNode.outgoing[#fromNode.outgoing + 1] = { node = toNode, pin = toPin, fromPin = fromPin }
  return self
end

function Graph:clearSpawned()
  for i = 1, #self.spawnedIds do
    local id = self.spawnedIds[i]
    local obj = Sim.findObjectById(id)
    if obj then
      if editor and editor.deleteObject then
        editor.deleteObject(id)
      else
        obj:delete()
      end
    end
  end
  table.clear(self.spawnedIds)

  -- Also wipe tracked output groups so re-runs after reload / lost IDs don't stack duplicates.
  if self.spawnGroups then
    for name, _ in pairs(self.spawnGroups) do
      local grp = scenetree.findObject(name)
      if grp and grp.getCount then
        local ids = {}
        for i = 0, grp:getCount() - 1 do
          local o = grp:getObject(i)
          if o then ids[#ids + 1] = o:getID() end
        end
        for j = 1, #ids do
          if editor and editor.deleteObject then
            editor.deleteObject(ids[j])
          else
            local o = Sim.findObjectById(ids[j])
            if o then o:delete() end
          end
        end
      end
    end
  end
  return self
end

function Graph:clear()
  return self:clearSpawned()
end

local function trackSpawnGroup(graph, groupName)
  if not groupName or groupName == "" then return end
  graph.spawnGroups = graph.spawnGroups or {}
  graph.spawnGroups[groupName] = true
end

local function ensureGroup(name)
  name = name or "PCG_Generated"
  local existing = scenetree.findObject(name)
  if existing then return existing end
  local grp = createObject("SimGroup")
  grp:registerObject(name)
  local parent = scenetree.MissionGroup
  if editor and editor.resolveAddGroup then
    parent = editor.resolveAddGroup(parent) or parent
  end
  if parent then
    parent:addObject(grp)
  end
  if editor and editor.setDirty then
    editor.setDirty()
  end
  return grp
end

local function topoOrder(nodes)
  local indeg = {}
  local byId = {}
  for i = 1, #nodes do
    local n = nodes[i]
    byId[n.id] = n
    indeg[n.id] = 0
  end
  for i = 1, #nodes do
    local n = nodes[i]
    for __ in pairs(n.incoming) do
      indeg[n.id] = indeg[n.id] + 1
    end
  end
  local queue = {}
  for id, d in pairs(indeg) do
    if d == 0 then queue[#queue + 1] = byId[id] end
  end
  local order = {}
  local qh = 1
  while qh <= #queue do
    local n = queue[qh]
    qh = qh + 1
    order[#order + 1] = n
    for i = 1, #n.outgoing do
      local dst = n.outgoing[i].node
      indeg[dst.id] = indeg[dst.id] - 1
      if indeg[dst.id] == 0 then
        queue[#queue + 1] = dst
      end
    end
  end
  if #order ~= #nodes then
    log("E", "pcg", "procedural graph has a cycle")
  end
  return order
end

function Graph:run(opts)
  opts = opts or {}
  local replace = opts.replace ~= false
  if replace then
    for i = 1, #self.nodes do
      local p = self.nodes[i].params
      if p and p.group then
        trackSpawnGroup(self, p.group)
      end
    end
    self:clearSpawned()
  end

  local seed = opts.seed or self.seed
  local ctx = {
    graph = self,
    rng = makeRng(seed),
    seed = seed,
  }

  local order = topoOrder(self.nodes)
  for i = 1, #order do
    local node = order[i]
    node.outputs = {}
    if node.execute then
      node.execute(node, ctx, resolvePin)
    end
  end

  if editor and editor.setDirty then
    editor.setDirty()
  end

  return {
    spawnedIds = self.spawnedIds,
    nodes = #self.nodes,
  }
end

local function pipeFrom(graph, node, pin)
  return setmetatable({ graph = graph, node = node, pin = pin or "points" }, Pipe)
end

function Pipe:connectTo(toNode, toPin)
  self.graph:connect(self.node, self.pin, toNode, toPin or "points")
  return pipeFrom(self.graph, toNode, toPin or "points")
end

-------------------------------------------------------------------------------
-- Generators
-------------------------------------------------------------------------------

local function execScatterBox(node, ctx, get)
  local p = node.params
  local center = toVec3(get(node, "center") or p.center)
  local extent = toVec3(get(node, "extent") or p.extent or vec3(10, 10, 0))
  local count = math.floor(tonumber(get(node, "count") or p.count) or 0)
  local half = extent * 0.5
  local points = {}
  for i = 1, count do
    points[i] = newPoint({
      pos = vec3(
        center.x + (ctx.rng() * 2 - 1) * half.x,
        center.y + (ctx.rng() * 2 - 1) * half.y,
        center.z + (ctx.rng() * 2 - 1) * half.z
      ),
      spawnRandomness = ctx.rng(),
    })
  end
  node.outputs.points = points
end

local function execScatterGrid(node, ctx, get)
  local p = node.params
  local center = toVec3(get(node, "center") or p.center)
  local extent = toVec3(get(node, "extent") or p.extent or vec3(10, 10, 0))
  local spacing = toVec3(get(node, "spacing") or p.spacing or vec3(2, 2, 2))
  local jitter = tonumber(get(node, "jitter") or p.jitter) or 0
  local half = extent * 0.5
  local sx = math.max(spacing.x, 1e-4)
  local sy = math.max(spacing.y, 1e-4)
  local sz = math.max(spacing.z, 1e-4)
  local points = {}
  local x0, x1 = center.x - half.x, center.x + half.x
  local y0, y1 = center.y - half.y, center.y + half.y
  local z0, z1 = center.z - half.z, center.z + half.z
  for x = x0, x1 + 1e-6, sx do
    for y = y0, y1 + 1e-6, sy do
      for z = z0, z1 + 1e-6, sz do
        local jx, jy, jz = 0, 0, 0
        if jitter > 0 then
          jx = (ctx.rng() * 2 - 1) * jitter
          jy = (ctx.rng() * 2 - 1) * jitter
          jz = (ctx.rng() * 2 - 1) * jitter
        end
        points[#points + 1] = newPoint({
          pos = vec3(x + jx, y + jy, z + jz),
          spawnRandomness = ctx.rng(),
        })
      end
    end
  end
  node.outputs.points = points
end

local function execScatterDisk(node, ctx, get)
  local p = node.params
  local center = toVec3(get(node, "center") or p.center)
  local radius = tonumber(get(node, "radius") or p.radius) or 10
  local inner = tonumber(get(node, "innerRadius") or p.innerRadius) or 0
  local count = math.floor(tonumber(get(node, "count") or p.count) or 0)
  local points = {}
  for i = 1, count do
    local a = ctx.rng() * math.pi * 2
    local r = math.sqrt(inner * inner + (radius * radius - inner * inner) * ctx.rng())
    points[i] = newPoint({
      pos = vec3(center.x + math.cos(a) * r, center.y + math.sin(a) * r, center.z),
      spawnRandomness = ctx.rng(),
    })
  end
  node.outputs.points = points
end

local function buildPath(path, closed)
  local pts = {}
  for i = 1, #(path or {}) do
    pts[i] = toVec3(path[i])
  end
  if closed and #pts > 1 then
    pts[#pts + 1] = vec3(pts[1])
  end
  local cum = { 0 }
  local total = 0
  for i = 2, #pts do
    total = total + (pts[i] - pts[i - 1]):length()
    cum[i] = total
  end
  return pts, cum, total
end

local function samplePath(pts, cum, dist)
  if #pts == 0 then return vec3(0, 0, 0), vec3(0, 1, 0) end
  if #pts == 1 or cum[#cum] <= 1e-9 then
    local t = #pts > 1 and (pts[2] - pts[1]) or vec3(0, 1, 0)
    if t:length() < 1e-9 then t = vec3(0, 1, 0) else t:normalize() end
    return vec3(pts[1]), t
  end
  if dist <= 0 then
    local t = pts[2] - pts[1]
    if t:length() < 1e-9 then t = vec3(0, 1, 0) else t:normalize() end
    return vec3(pts[1]), t
  end
  local total = cum[#cum]
  if dist >= total then
    local t = pts[#pts] - pts[#pts - 1]
    if t:length() < 1e-9 then t = vec3(0, 1, 0) else t:normalize() end
    return vec3(pts[#pts]), t
  end
  local lo, hi = 1, #cum
  while lo < hi do
    local mid = math.floor((lo + hi) * 0.5)
    if cum[mid] < dist then lo = mid + 1 else hi = mid end
  end
  local i = math.max(2, lo)
  local d0, d1 = cum[i - 1], cum[i]
  local seg = d1 - d0
  local t = seg > 1e-9 and ((dist - d0) / seg) or 0
  local a, b = pts[i - 1], pts[i]
  local dir = b - a
  local tangent = vec3(dir)
  if tangent:length() < 1e-9 then tangent = vec3(0, 1, 0) else tangent:normalize() end
  return a + dir * t, tangent
end

local function collectSplineDistances(mode, total, params, rng)
  local distances = {}
  mode = mode or "equal"
  if mode == "fixed" and type(params.distances) == "table" then
    for i = 1, #params.distances do
      distances[#distances + 1] = tonumber(params.distances[i]) or 0
    end
    return distances
  end
  if mode == "count" then
    local count = math.max(0, math.floor(tonumber(params.count) or 0))
    if count == 1 then
      distances[1] = total * 0.5
    elseif count > 1 then
      for i = 0, count - 1 do
        distances[#distances + 1] = total * (i / (count - 1))
      end
    end
    return distances
  end
  if mode == "random" then
    local count = math.max(0, math.floor(tonumber(params.count) or 0))
    local minSpacing = tonumber(params.minSpacing) or 0
    local tries = 0
    while #distances < count and tries < count * 40 do
      tries = tries + 1
      local d = rng() * total
      local ok = true
      if minSpacing > 0 then
        for i = 1, #distances do
          if math.abs(distances[i] - d) < minSpacing then
            ok = false
            break
          end
        end
      end
      if ok then distances[#distances + 1] = d end
    end
    table.sort(distances)
    return distances
  end
  -- equal / fixed spacing
  local spacing = tonumber(params.spacing) or 2
  if spacing <= 1e-6 then spacing = 2 end
  local d = tonumber(params.startOffset) or 0
  while d <= total + 1e-6 do
    distances[#distances + 1] = d
    d = d + spacing
  end
  return distances
end

local function execScatterAlongSpline(node, ctx, get)
  local p = node.params
  local path = get(node, "path") or p.path or {}
  local closed = get(node, "closed")
  if closed == nil then closed = p.closed end
  local pts, cum, total = buildPath(path, closed)
  local mode = get(node, "mode") or p.mode or "equal"
  local distances = collectSplineDistances(mode, total, {
    count = get(node, "count") or p.count,
    spacing = get(node, "spacing") or p.spacing,
    minSpacing = get(node, "minSpacing") or p.minSpacing,
    distances = get(node, "distances") or p.distances,
    startOffset = get(node, "startOffset") or p.startOffset,
  }, ctx.rng)

  local lateralJitter = tonumber(get(node, "lateralJitter") or p.lateralJitter) or 0
  local upJitter = tonumber(get(node, "upJitter") or p.upJitter) or 0
  local align = get(node, "alignToTangent")
  if align == nil then align = p.alignToTangent end
  if align == nil then align = true end

  local points = {}
  for i = 1, #distances do
    local pos, tangent = samplePath(pts, cum, distances[i])
    if lateralJitter > 0 then
      local side = vec3(-tangent.y, tangent.x, 0)
      if side:length() > 1e-9 then
        side:normalize()
        pos = pos + side * ((ctx.rng() * 2 - 1) * lateralJitter)
      end
    end
    if upJitter > 0 then
      pos = pos + vec3(0, 0, (ctx.rng() * 2 - 1) * upJitter)
    end
    local rot = quat(identityQuat)
    if align then
      rot = quatFromDir(tangent, vec3(0, 0, 1))
    end
    points[#points + 1] = newPoint({
      pos = pos,
      rot = rot,
      spawnRandomness = ctx.rng(),
    })
  end
  node.outputs.points = points
end

local function execFromPoints(node, ctx, get)
  local pts = get(node, "points") or node.params.points or {}
  node.outputs.points = copyPoints(pts)
end

local function copySegment(seg)
  if seg.nodes then
    local nodes = {}
    for i = 1, #seg.nodes do
      local n = seg.nodes[i]
      nodes[i] = { pos = toVec3(n.pos or n), width = tonumber(n.width) or seg.width }
    end
    return { nodes = nodes, width = tonumber(seg.width) }
  end
  if seg.path then
    local path = {}
    for i = 1, #seg.path do path[i] = toVec3(seg.path[i]) end
    return { path = path, width = tonumber(seg.width) }
  end
  return {
    a = toVec3(seg.a),
    b = toVec3(seg.b),
    width = tonumber(seg.width),
    mid = seg.mid and toVec3(seg.mid) or nil,
    tangent = seg.tangent and toVec3(seg.tangent) or nil,
    length = seg.length,
  }
end

local function execFromSegments(node, ctx, get)
  local segs = get(node, "segments") or node.params.segments or {}
  local out = {}
  for i = 1, #segs do
    out[i] = copySegment(segs[i])
  end
  node.outputs.segments = out
end

-------------------------------------------------------------------------------
-- Transforms
-------------------------------------------------------------------------------

local function mapPoints(node, ctx, get, fn)
  local input = get(node, "points") or {}
  local out = {}
  for i = 1, #input do
    out[i] = fn(copyPoint(input[i]), ctx, i)
  end
  node.outputs.points = out
end

local function execRandomTransform(node, ctx, get)
  local p = node.params
  mapPoints(node, ctx, get, function(pt)
    local yaw = rangeValue(ctx.rng, get(node, "yaw") or p.yaw)
    local pitch = rangeValue(ctx.rng, get(node, "pitch") or p.pitch)
    local roll = rangeValue(ctx.rng, get(node, "roll") or p.roll)
    if yaw or pitch or roll then
      local add = quatFromEuler(
        math.rad(pitch or 0),
        math.rad(roll or 0),
        math.rad(yaw or 0)
      )
      pt.rot = add * pt.rot
    end
    local scale = get(node, "scale") or p.scale
    if type(scale) == "number" then
      local s = scale
      pt.scale = vec3(s, s, s)
    elseif type(scale) == "table" then
      if scale.min or scale[1] then
        local s = rangeValue(ctx.rng, scale)
        pt.scale = vec3(s, s, s)
      else
        local sx = rangeValue(ctx.rng, scale.x) or pt.scale.x
        local sy = rangeValue(ctx.rng, scale.y) or pt.scale.y
        local sz = rangeValue(ctx.rng, scale.z) or pt.scale.z
        pt.scale = vec3(sx, sy, sz)
      end
    end
    return pt
  end)
end

local function execSetSpawnRandomness(node, ctx, get)
  local p = node.params
  local value = get(node, "value") or p.value
  local range = get(node, "range") or p.range
  mapPoints(node, ctx, get, function(pt)
    if value ~= nil then
      pt.spawnRandomness = tonumber(value) or 0
    elseif range ~= nil then
      pt.spawnRandomness = rangeValue(ctx.rng, range) or 0
    else
      pt.spawnRandomness = ctx.rng()
    end
    if pt.spawnRandomness < 0 then pt.spawnRandomness = 0 end
    if pt.spawnRandomness > 1 then pt.spawnRandomness = 1 end
    return pt
  end)
end

local function execSnapTerrain(node, ctx, get)
  local p = node.params
  local offset = tonumber(get(node, "offset") or p.offset) or 0
  mapPoints(node, ctx, get, function(pt)
    if core_terrain and core_terrain.getTerrainHeight then
      local h = core_terrain.getTerrainHeight(pt.pos)
      if h then
        pt.pos.z = h + offset
      end
    end
    return pt
  end)
end

local function execOffset(node, ctx, get)
  local p = node.params
  local delta = toVec3(get(node, "delta") or p.delta)
  local random = get(node, "random") or p.random
  mapPoints(node, ctx, get, function(pt)
    local d = vec3(delta)
    if random then
      local r = toVec3(random)
      d = d + vec3((ctx.rng() * 2 - 1) * r.x, (ctx.rng() * 2 - 1) * r.y, (ctx.rng() * 2 - 1) * r.z)
    end
    pt.pos = pt.pos + d
    return pt
  end)
end

local function execFilterBounds(node, ctx, get)
  local p = node.params
  local minP = toVec3(get(node, "min") or p.min)
  local maxP = toVec3(get(node, "max") or p.max)
  local center = get(node, "center") or p.center
  local radius = get(node, "radius") or p.radius
  local input = get(node, "points") or {}
  local out = {}
  for i = 1, #input do
    local pt = copyPoint(input[i])
    local keep = true
    if center and radius then
      keep = (pt.pos - toVec3(center)):length() <= tonumber(radius)
    else
      keep = pt.pos.x >= minP.x and pt.pos.x <= maxP.x
        and pt.pos.y >= minP.y and pt.pos.y <= maxP.y
        and pt.pos.z >= minP.z and pt.pos.z <= maxP.z
    end
    if keep then out[#out + 1] = pt end
  end
  node.outputs.points = out
end

-------------------------------------------------------------------------------
-- Spawners
-------------------------------------------------------------------------------

local function trackSpawn(graph, obj)
  if not obj then return end
  local id = obj.getID and obj:getID() or obj:getId()
  graph.spawnedIds[#graph.spawnedIds + 1] = id
end

local function spawnPointsWithPicker(node, ctx, get, picker)
  local points = get(node, "points") or {}
  local groupName = get(node, "group") or node.params.group or "PCG_Generated"
  local namePrefix = get(node, "namePrefix") or node.params.namePrefix or node.kind
  trackSpawnGroup(ctx.graph, groupName)
  local group = ensureGroup(groupName)
  local created = {}
  for i = 1, #points do
    local pt = points[i]
    local obj = picker(pt, i)
    if obj then
      applyPosRotScale(obj, pt)
      if group then group:addObject(obj) end
      trackSpawn(ctx.graph, obj)
      created[#created + 1] = obj.getID and obj:getID() or obj:getId()
    end
  end
  node.outputs.objectIds = created
  node.outputs.points = points
end

local function execSpawnStatic(node, ctx, get)
  local paths = get(node, "paths") or node.params.paths or {}
  local namePrefix = get(node, "namePrefix") or node.params.namePrefix or "pcg_static"
  spawnPointsWithPicker(node, ctx, get, function(pt, i)
    local shape = pt.shape or pt.shapeName or pt.path
    if not shape then
      local idx
      idx, shape = listIndex(paths, pt.spawnRandomness)
    end
    if not shape then return nil end
    local obj = createObject("TSStatic")
    obj:setField("shapeName", 0, tostring(shape))
    obj:setField("collisionType", 0, node.params.collisionType or "Collision Mesh")
    obj:setField("decalType", 0, node.params.decalType or "Collision Mesh")
    obj:setField("instanceColor", 0, colorToString(pt.color))
    obj.useInstanceRenderData = true
    obj.canSave = true
    obj:registerObject(Sim.getUniqueName(string.format("%s_%d", namePrefix, i)))
    return obj
  end)
end

local function execSpawnPrefab(node, ctx, get)
  local paths = get(node, "paths") or node.params.paths or {}
  local namePrefix = get(node, "namePrefix") or node.params.namePrefix or "pcg_prefab"
  spawnPointsWithPicker(node, ctx, get, function(pt, i)
    local _, path = listIndex(paths, pt.spawnRandomness)
    if not path or not spawnPrefab then return nil end
    local name = Sim.getUniqueName(string.format("%s_%d", namePrefix, i))
    local obj = spawnPrefab(name, tostring(path), posToString(pt.pos), rotToString(pt.rot), scaleToString(pt.scale))
    if obj and obj.loadMode ~= nil then
      obj.loadMode = 0
    end
    return obj
  end)
end

local function execSpawnClass(node, ctx, get)
  local classes = get(node, "classes") or node.params.classes or {}
  local namePrefix = get(node, "namePrefix") or node.params.namePrefix or "pcg_class"
  local fields = get(node, "fields") or node.params.fields
  spawnPointsWithPicker(node, ctx, get, function(pt, i)
    local _, className = listIndex(classes, pt.spawnRandomness)
    if not className then return nil end
    local obj = createObject(tostring(className))
    if not obj then return nil end
    if type(fields) == "table" then
      for k, v in pairs(fields) do
        obj:setField(tostring(k), 0, tostring(v))
      end
    end
    obj:registerObject(Sim.getUniqueName(string.format("%s_%d", namePrefix, i)))
    return obj
  end)
end

local function segmentToRoadNodes(seg, defaultWidth, snapTerrain)
  local width = tonumber(seg.width) or defaultWidth or 8
  local nodes = {}
  if seg.nodes and #seg.nodes >= 2 then
    for i = 1, #seg.nodes do
      local n = seg.nodes[i]
      local pos = toVec3(n.pos or n)
      if snapTerrain then
        pos.z = (core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos)) or pos.z
      end
      nodes[#nodes + 1] = { pos = pos, width = tonumber(n.width) or width }
    end
  elseif seg.path and #seg.path >= 2 then
    for i = 1, #seg.path do
      local pos = toVec3(seg.path[i])
      if snapTerrain then
        pos.z = (core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos)) or pos.z
      end
      nodes[#nodes + 1] = { pos = pos, width = width }
    end
  elseif seg.a and seg.b then
    local a = toVec3(seg.a)
    local b = toVec3(seg.b)
    if snapTerrain then
      a.z = (core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(a)) or a.z
      b.z = (core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(b)) or b.z
    end
    nodes[1] = { pos = a, width = width }
    nodes[2] = { pos = b, width = width }
  end
  return nodes
end

local function execSpawnDecalRoads(node, ctx, get)
  local segments = get(node, "segments") or node.params.segments or {}
  local groupName = get(node, "group") or node.params.group or "PCG_Generated"
  local namePrefix = get(node, "namePrefix") or node.params.namePrefix or "pcg_road"
  local material = get(node, "material") or node.params.material or "road_asphalt_2lane"
  local defaultWidth = tonumber(get(node, "width") or node.params.width) or 8
  local snap = get(node, "snapTerrain")
  if snap == nil then snap = node.params.snapTerrain end
  if snap == nil then snap = true end
  local overObjects = get(node, "overObjects")
  if overObjects == nil then overObjects = node.params.overObjects end
  if overObjects == nil then overObjects = not (core_terrain and core_terrain.getTerrain and core_terrain.getTerrain()) end
  local drivability = get(node, "drivability") or node.params.drivability or 1
  local textureLength = get(node, "textureLength") or node.params.textureLength or 50
  local improvedSpline = get(node, "improvedSpline")
  if improvedSpline == nil then improvedSpline = node.params.improvedSpline end
  if improvedSpline == nil then improvedSpline = true end

  local group = ensureGroup(groupName)
  trackSpawnGroup(ctx.graph, groupName)
  local created = {}

  for i = 1, #segments do
    local nodes = segmentToRoadNodes(segments[i], defaultWidth, snap)
    if #nodes >= 2 then
      local road = createObject("DecalRoad")
      road:setField("improvedSpline", 0, improvedSpline and "true" or "false")
      road:setField("material", 0, tostring(material))
      road:setField("overObjects", 0, overObjects and "true" or "false")
      road:setField("drivability", 0, tostring(drivability))
      road:setField("textureLength", 0, tostring(textureLength))
      road:registerObject(Sim.getUniqueName(string.format("%s_%d", namePrefix, i)))
      for index, n in ipairs(nodes) do
        road:insertNode(n.pos, n.width, index - 1)
      end
      if road.regenerate then road:regenerate() end
      if group then group:addObject(road) end
      trackSpawn(ctx.graph, road)
      created[#created + 1] = road:getID()
    end
  end

  node.outputs.objectIds = created
  node.outputs.segments = segments
end

-------------------------------------------------------------------------------
-- Factories + fluent
-------------------------------------------------------------------------------

local factories = {
  scatterBox = function(params) return newNode("scatterBox", params, execScatterBox) end,
  scatterGrid = function(params) return newNode("scatterGrid", params, execScatterGrid) end,
  scatterDisk = function(params) return newNode("scatterDisk", params, execScatterDisk) end,
  scatterAlongSpline = function(params) return newNode("scatterAlongSpline", params, execScatterAlongSpline) end,
  fromPoints = function(params) return newNode("fromPoints", params, execFromPoints) end,
  fromSegments = function(params) return newNode("fromSegments", params, execFromSegments) end,
  randomTransform = function(params) return newNode("randomTransform", params, execRandomTransform) end,
  setSpawnRandomness = function(params) return newNode("setSpawnRandomness", params, execSetSpawnRandomness) end,
  snapTerrain = function(params) return newNode("snapTerrain", params, execSnapTerrain) end,
  offset = function(params) return newNode("offset", params, execOffset) end,
  filterBounds = function(params) return newNode("filterBounds", params, execFilterBounds) end,
  spawnStatic = function(params) return newNode("spawnStatic", params, execSpawnStatic) end,
  spawnPrefab = function(params) return newNode("spawnPrefab", params, execSpawnPrefab) end,
  spawnClass = function(params) return newNode("spawnClass", params, execSpawnClass) end,
  spawnDecalRoads = function(params) return newNode("spawnDecalRoads", params, execSpawnDecalRoads) end,
}

local function addFactory(graph, kind, params)
  local node = graph:_addNode(factories[kind](params or {}))
  return pipeFrom(graph, node, "points")
end

local function chainFactory(pipe, kind, params)
  local node = pipe.graph:_addNode(factories[kind](params or {}))
  pipe.graph:connect(pipe.node, pipe.pin, node, "points")
  return pipeFrom(pipe.graph, node, "points")
end

local function chainSpawn(pipe, kind, params, inPin)
  local node = pipe.graph:_addNode(factories[kind](params or {}))
  pipe.graph:connect(pipe.node, pipe.pin, node, inPin or "points")
  return pipe.graph
end

function Graph:scatterBox(params) return addFactory(self, "scatterBox", params) end
function Graph:scatterGrid(params) return addFactory(self, "scatterGrid", params) end
function Graph:scatterDisk(params) return addFactory(self, "scatterDisk", params) end
function Graph:scatterAlongSpline(params) return addFactory(self, "scatterAlongSpline", params) end
function Graph:fromPoints(params) return addFactory(self, "fromPoints", params) end
function Graph:fromSegments(params)
  local node = self:_addNode(factories.fromSegments(params or {}))
  return pipeFrom(self, node, "segments")
end

function Graph:add(kindOrNode, params)
  if type(kindOrNode) == "table" and kindOrNode.execute then
    return pipeFrom(self, self:_addNode(kindOrNode), "points")
  end
  if type(kindOrNode) ~= "string" or not factories[kindOrNode] then
    log("E", "pcg", "unknown pcg node: " .. tostring(kindOrNode))
    return nil
  end
  return addFactory(self, kindOrNode, params)
end

function Pipe:randomTransform(params) return chainFactory(self, "randomTransform", params) end
function Pipe:setSpawnRandomness(params) return chainFactory(self, "setSpawnRandomness", params) end
function Pipe:snapTerrain(params) return chainFactory(self, "snapTerrain", params) end
function Pipe:offset(params) return chainFactory(self, "offset", params) end
function Pipe:filterBounds(params) return chainFactory(self, "filterBounds", params) end
function Pipe:spawnStatic(params) return chainSpawn(self, "spawnStatic", params, "points") end
function Pipe:spawnPrefab(params) return chainSpawn(self, "spawnPrefab", params, "points") end
function Pipe:spawnClass(params) return chainSpawn(self, "spawnClass", params, "points") end
function Pipe:spawnDecalRoads(params) return chainSpawn(self, "spawnDecalRoads", params, "segments") end
function Pipe:run(opts) return self.graph:run(opts) end
function Pipe:clear() return self.graph:clear() end
function Pipe:rebuild() return self.graph:rebuild() end

local graphs = {}

function Graph:rebuild()
  self.nodes = {}
  return self
end

local function newGraphInstance(opts)
  opts = opts or {}
  return setmetatable({
    name = opts.name,
    seed = opts.seed or 1,
    nodes = {},
    spawnedIds = {},
    spawnGroups = {},
  }, Graph)
end

-- graph("name") / graph("name", opts) returns a cached graph (spawnedIds preserved).
-- graph(opts) / graph() creates an anonymous uncached graph.
local function createGraph(nameOrOpts, opts)
  if type(nameOrOpts) == "string" then
    local name = nameOrOpts
    opts = opts or {}
    local existing = graphs[name]
    if existing then
      if opts.seed ~= nil then existing.seed = opts.seed end
      return existing
    end
    local g = newGraphInstance(opts)
    g.name = name
    graphs[name] = g
    return g
  end
  return newGraphInstance(type(nameOrOpts) == "table" and nameOrOpts or {})
end

local function listGraphs()
  local names = {}
  for name, _ in pairs(graphs) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function getGraph(name)
  return graphs[name]
end

-- removeGraph(name, deleteOwnedObjects)
-- deleteOwnedObjects defaults to true: deletes spawned scene objects, then drops the cache entry.
-- Pass false to forget the graph but leave its objects in the scene.
local function removeGraph(name, deleteOwnedObjects)
  local g = graphs[name]
  if not g then return false end
  if deleteOwnedObjects ~= false then
    g:clearSpawned()
  else
    table.clear(g.spawnedIds)
  end
  graphs[name] = nil
  return true
end

-- clearAllGraphs(deleteOwnedObjects) — same bool semantics as removeGraph.
local function clearAllGraphs(deleteOwnedObjects)
  local names = listGraphs()
  for i = 1, #names do
    removeGraph(names[i], deleteOwnedObjects)
  end
end

function Graph:destroy(deleteOwnedObjects)
  if self.name and graphs[self.name] == self then
    return removeGraph(self.name, deleteOwnedObjects)
  end
  if deleteOwnedObjects ~= false then
    self:clearSpawned()
  else
    table.clear(self.spawnedIds)
  end
  return true
end

local function initialize(editorInstance)
  editor = editorInstance
  local api = {
    graph = createGraph,
    graphs = graphs,
    listGraphs = listGraphs,
    getGraph = getGraph,
    removeGraph = removeGraph,
    clearAllGraphs = clearAllGraphs,
    newPoint = newPoint,
    nodes = factories,
  }
  editor.pcg = api
  editor.proceduralContentGenerator = api
end

local M = {}
M.initialize = initialize
M.graph = createGraph
M.graphs = graphs
M.listGraphs = listGraphs
M.getGraph = getGraph
M.removeGraph = removeGraph
M.clearAllGraphs = clearAllGraphs
M.newPoint = newPoint
M.nodes = factories

return M
