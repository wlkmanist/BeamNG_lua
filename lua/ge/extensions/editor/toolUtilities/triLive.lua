-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- What a kit actually costs to draw from where the camera is standing, rather than what it costs on paper: every instance
-- priced at the LOD it is really drawing, less the ones off screen.
--
-- Serves whichever tool is in front of the user - one building in the massing editor, a whole street in the placer - and holds
-- one answer at a time, which is all there is to hold: the editor runs one edit mode. The measured LOD ladders are the costly
-- part and they are shared, so a shape a building was priced on is already priced when a street of them is placed.

local M = {}

-- Module constants.
local sqrt, tan, rad, max, min = math.sqrt, math.tan, math.rad, math.max, math.min
local CACHE_PATH = '/temp/massingEditor/shapeLods.json'
local ENGINE_SCALE = 4.48
local UPDATE_HZ = 4
local SLICE = 10000      -- instances priced per frame: a street is one frame, a town of hundreds of thousands is spread out

-- Module state.
local cache = {}         -- shapePath -> { lods = { { size, polys }, ... }, col }, persisted
local radii = {}         -- shapePath -> bounding radius, NOT persisted: see radiusOf
local walked = {}        -- shapes the last scene walk could not find, until the list changes
local cacheLoaded = false
local cacheDirty = false
local pending = {}       -- shape paths still waiting on a scan
local pendingN = 0
local failed = {}        -- shapes this session could not measure, NOT persisted: see scanStep
local preview, rectI = nil, nil
local last = { tris = 0, dist = 0, live = 0, total = 0, at = -1 }
local walk = { i = 0 }   -- the pass in progress: where it has got to, and the view and sums it was started with


--- Every entry carries the write time of the file it was measured from and is checked against it in `note`, so an entry
--- this file has no use for - one from an older shape of this table, or one measured from a shape since rebaked - throws
--- itself out the first time it is looked at. There is nothing here to version.
local function loadCache()
  if cacheLoaded then return end
  cacheLoaded = true
  local ok, data = pcall(jsonReadFile, CACHE_PATH)
  if not (ok and type(data) == 'table') then return end
  for path, e in pairs(data) do
    if type(e) == 'table' and type(e.lods) == 'table' then cache[path] = e end
  end
end

local function saveCache()
  if not cacheDirty then return end
  pcall(jsonWriteFile, CACHE_PATH, cache, true)
  cacheDirty = false
end

--- The scaled radius of whatever instance of `path` is in the scene, which is what the LOD pick actually tests. It has to come
--- off a live object, because the shape's own bounds are not exposed to Lua.
---
--- That makes it scene state and not file state, so it is resolved here and never written to the cache: a rebuild deletes
--- every instance for a frame or two, and a radius measured on one of those frames is zero. Cached, that zero would stick
--- and the shape would be silently left out of the total for the rest of the session.
local function boxRadius(o)
  local n = {}
  for v in tostring(o:getWorldBox()):gmatch('-?%d+%.?%d*') do n[#n + 1] = tonumber(v) end
  if #n < 6 then return nil end
  local dx, dy, dz = (n[4] - n[1]) * 0.5, (n[5] - n[2]) * 0.5, (n[6] - n[3]) * 0.5
  return sqrt(dx * dx + dy * dy + dz * dz)
end

--- Fill in any radius we are still missing: off the instance's own forest item or TSStatic where the entry carries one, else
--- in ONE walk of the scene rather than one walk per shape. A shape that walk cannot find is not walked for again until the
--- list changes (`note`): a scene of a hundred thousand statics is most of a second to walk.
local function refreshRadii(instances)
  local want = nil
  for i = 1, #instances do
    local it = instances[i]
    local s = it.shape
    if s and not radii[s] and not walked[s] then
      local o = it.item or (it.obj and simObjectExists(it.obj) and it.obj)
      radii[s] = o and boxRadius(o) or nil
      if not radii[s] then want = want or {}; want[s] = true end
    end
  end
  if not want then return end
  for s in pairs(want) do walked[s] = true end
  for _, id in ipairs(scenetree.findClassObjects('TSStatic')) do
    local o = scenetree.findObject(id)
    local s = o and o.shapeName
    if s and want[s] then
      radii[s] = boxRadius(o)
      if radii[s] then want[s] = nil end
    end
  end
end

local function bySizeDesc(a, b)
  return a.size > b.size
end

--- When the shape's own file was last written, which is what makes a cached ladder still true. A rebake replaces the
--- ladder under a cached answer, and a cache that could not notice went on pricing a kit off the LODs it had BEFORE the
--- bake - for the rest of the session and, being on disk, for every session after it.
local function modTime(path)
  local ok, st = pcall(function() return FS:stat(path) end)
  return (ok and type(st) == 'table' and st.modtime) or 0
end

--- Every LOD of one shape as { size, polys }, biggest size (nearest) first. `size` is the engine's own pixel threshold: a
--- level draws while the projected size is at or above it, so the last entry is the floor and runs on for ever.
local function ladderOf(path)
  if not preview then preview = ShapePreview(); rectI = RectI(0, 0, 256, 256) end
  preview:clearShape()
  preview:setObjectModel(path)
  local info = preview:getTSShapeInfo()
  local dc = preview:getDetailLevelCount() or 0
  preview.mFixedDetail = true
  local lods = {}
  for d = 0, dc - 1 do
    local det = info and info.details and info.details[d + 1]
    local size = det and det.size or -1
    if size >= 0 then                                  -- negative size is the collision detail, not a draw level
      preview:setCurrentDetail(d)
      preview:renderWorld(rectI)
      lods[#lods + 1] = { size = size, polys = preview.mDetailPolys or 0 }
    end
  end
  table.sort(lods, bySizeDesc)
  return { lods = lods, col = preview.mColPolys or 0, mt = modTime(path) }
end

--- Queue any shape in `instances` we have never measured. Cheap enough to call every rebuild.
local function note(instances)
  loadCache()
  table.clear(walked)
  local seen = {}
  for i = 1, #instances do
    local s = instances[i].shape
    if s and not seen[s] then
      seen[s] = true
      -- A shape whose file has been written since it was measured is treated as one we have never measured. Rebaking a
      -- kit and then reading the counter is the whole workflow here, so it has to be the case that works.
      local e = cache[s]
      if e and e.mt ~= modTime(s) then cache[s], failed[s] = nil, nil; e = nil end
      if not e and not pending[s] and not failed[s] then pending[s] = true; pendingN = pendingN + 1 end
    end
  end
end

--- One shape per call. Called from the editor's own frame, so the cold scan shows as progress rather than as a freeze.
local function scanStep()
  if pendingN == 0 then
    if cacheDirty then saveCache() end
    return false
  end
  local path = next(pending)
  if not path then pendingN = 0; return false end
  pending[path] = nil
  pendingN = pendingN - 1
  local ok, res = pcall(ladderOf, path)
  -- A shape we could not measure must NOT be remembered as "measured, and it draws nothing".
  if ok and res and res.lods and #res.lods > 0 then
    cache[path] = res
    cacheDirty = true
  else
    failed[path] = true
    log('W', 'triLive', 'could not measure LOD ladder for ' .. tostring(path) .. ' - not counted, will retry next reload')
  end
  if pendingN == 0 then saveCache() end
  return true
end

--- Pixels per metre of radius at the live FOV and window height, plus the tangent of the view's half-diagonal. The LOD pick
--- is a screen-size test, so a zoomed camera or a bigger window keeps everything alive further out. The engine's own size
--- runs ENGINE_SCALE times the half-height over tan(fov/2), measured on a probe shape at 1920x1009 and 65 degrees.
local function view()
  local fov = core_camera and core_camera.getFovDeg and core_camera.getFovDeg() or 65
  if not fov or fov <= 1 then fov = 65 end
  local vm = GFXDevice.getVideoMode()
  local w, h = vm and vm.width or 1920, vm and vm.height or 1080
  local t = tan(rad(fov) * 0.5)
  local aspect = w / max(h, 1)
  return ENGINE_SCALE * h * 0.5 / t, t * sqrt(1 + aspect * aspect)
end

--- Triangles one instance of `e` draws at `dist`: the first level it is at least the size of, else the last one.
local function trisAt(e, r, dist, scale)
  local n = #e.lods
  if n == 0 or r <= 0 then return nil end
  local proj = scale * r / max(dist, 0.001)
  for i = 1, n do
    if proj >= e.lods[i].size then return e.lods[i].polys end
  end
  return e.lods[n].polys
end

--- Total instanced triangles on screen, plus the distance the answer is for. Throttled, since it is a number a human is
--- reading, and walked SLICE instances a frame: a placed town is hundreds of thousands of them, and pricing every one in a
--- single frame four times a second was a frame in every fifteen taking most of a tenth of a second.
local function update(instances)
  local n = #instances
  local w = walk
  if w.i > 0 and w.n ~= n then w.i = 0 end -- the list was rebuilt under the pass; its sums are of a list that has gone
  if w.i == 0 then
    local now = os.clock()
    if last.at >= 0 and now - last.at < 1 / UPDATE_HZ then return end
    last.at = now
    loadCache()
    local cam = core_camera and core_camera.getPosition and core_camera.getPosition() or nil
    if not cam or n == 0 then last.tris, last.dist, last.live, last.total = 0, 0, 0, 0; return end
    local fwd = core_camera.getForward()
    w.scale, w.tanD = view()
    w.secD = sqrt(1 + w.tanD * w.tanD)
    w.camX, w.camY, w.camZ, w.fx, w.fy, w.fz = cam.x, cam.y, cam.z, fwd.x, fwd.y, fwd.z
    w.i, w.n, w.tris, w.live, w.cx, w.cy, w.cz, w.missing = 1, n, 0, 0, 0, 0, 0, false
  end

  local camX, camY, camZ, fx, fy, fz = w.camX, w.camY, w.camZ, w.fx, w.fy, w.fz
  local scale, tanD, secD = w.scale, w.tanD, w.secD
  local tris, live, cx, cy, cz, missing = w.tris, w.live, w.cx, w.cy, w.cz, w.missing
  local stop = min(n, w.i + SLICE - 1)
  -- Counted against the whole list rather than against the instances we could price, so the two numbers the panel shows
  -- always add up. A shape whose scan failed, or whose radius could not be read yet, is simply not drawing.
  -- The view test is a cone round the screen's diagonal, so the corners just outside the screen still count.
  for i = w.i, stop do
    local it = instances[i]
    -- Centroid off the instance cloud rather than the footprint: it is what is actually being drawn.
    cx, cy, cz = cx + it.px, cy + it.py, cz + it.pz
    local s = it.shape
    local e = s and cache[s]
    local t
    if e then
      local r = radii[s]
      if not r then missing, r = true, 0 end
      local ex, ey, ez = it.px - camX, it.py - camY, it.pz - camZ
      local d2 = ex * ex + ey * ey + ez * ez
      local along = ex * fx + ey * fy + ez * fz
      if along > -r and sqrt(max(d2 - along * along, 0)) <= along * tanD + r * secD then
        t = trisAt(e, r, sqrt(d2), scale)
      end
    end
    if t and t > 0 then tris = tris + t; live = live + 1 end
  end
  w.tris, w.live, w.cx, w.cy, w.cz, w.missing = tris, live, cx, cy, cz, missing
  if stop < n then w.i = stop + 1; return end

  w.i = 0
  local inv = 1 / n
  local dx, dy, dz = camX - cx * inv, camY - cy * inv, camZ - cz * inv
  last.dist = sqrt(dx * dx + dy * dy + dz * dz)
  last.tris, last.live, last.total = tris, live, n
  -- After a rebuild: the next pass prices what this one could not.
  if missing then refreshRadii(instances) end
end

--- live instanced tris, distance to the instance centroid, instances drawing, instances placed, shapes still to scan
local function get()
  return last.tris, last.dist, last.live, last.total, pendingN
end

local function rescan()
  cache, radii, cacheLoaded, cacheDirty, pending, pendingN = {}, {}, true, true, {}, 0
  failed = {} -- a rescan is an explicit "try everything again", so past failures are forgotten too
end


-- Public interface.
M.note = note
M.scanStep = scanStep
M.update = update
M.get = get
M.rescan = rescan

return M