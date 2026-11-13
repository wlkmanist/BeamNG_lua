-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Parking spots as a site carries them, and as the level reads them back out of its sites file.
--
-- A spot is neither geometry nor paint: it is a box the game looks for when it wants somewhere to leave a car. So it
-- cannot go into a shell and it cannot be painted either -- it has to be written into the level's own `city.sites.json`,
-- which is the one thing a site bake produces that is not a file of its own.
--
-- That is why it waits for the burn. Authoring a car park happens on the site pad, far from where the lot will stand and
-- fifty metres up, so spots written then would describe the drawing board rather than the street. Baked LOCAL and written
-- at burn time, every copy of the lot gets its own spots at its own place and its own height, which is the whole point of
-- a library asset.
--
-- A run of bays that are the same size and stand shoulder to shoulder is written as ONE multi-spot rather than as five
-- boxes, which is what the hand-authored city spots do and what keeps the file readable.

local M = {}

-- Module constants.
local floor, cos, sin, atan2 = math.floor, math.cos, math.sin, math.atan2
local UP = vec3(0, 0, 1)
local MM = 1000
-- Box height. The position sits on the ground and the box reaches half this either side of it, which matches the spots
-- shipped with the hand-authored cities.
local SPOT_H = 3

local function round3(v) return floor(v * MM + 0.5) / MM end


--- The spots a site's own solver worked out, local to the bake origin.
---
--- Each one comes in as `{ x, y, yaw, w, d, n, dir }` in the frame the bake is being taken in: where its first bay's centre
--- is, which way a car parked in it faces, how wide and deep a bay is, how many bays the run holds, and which hand the run
--- steps along. Only the position is moved -- the heading stays as it was, and `place` adds the placement's own to it, the
--- same as every other list in a manifest.
local function localise(list, ox, oy)
  local n = #(list or {})
  if n == 0 then return nil end
  local out = {}
  for i = 1, n do
    local s = list[i]
    local rec = { x = round3(s.x - (ox or 0)), y = round3(s.y - (oy or 0)),
                  yaw = round3(s.yaw or 0), w = round3(s.w), d = round3(s.d) }
    -- Both left off a plain single bay, which is most of them.
    if (s.n or 1) > 1 then rec.n = s.n end
    if s.dir == 'Left' then rec.dir = 'Left' end
    out[#out + 1] = rec
  end
  return out
end

--- And back: the manifest's spots as `parkingSpot` records, stood where a placement is and turned onto its heading.
---
--- `ox, oy` is the point in the site's own frame the placement turns about -- the middle of its footprint rather than the
--- bake origin at a corner -- exactly as the marks and the kit are measured. `groundZ` answers the height at a point,
--- because a spot sits on the ground it is on and not at the placement's datum: a lot is graded flat, but its footway and
--- the street outside it are not, and the box has to sit where a car would.
---
--- No names here. Those have to be unique across the whole level file and are handed out by `write`.
local function place(rec, px, py, yaw, ox, oy, groundZ)
  local n = #(rec or {})
  if n == 0 then return nil end
  yaw = yaw or 0
  local c, s = cos(yaw), sin(yaw)
  local out = {}
  for i = 1, n do
    local sp = rec[i]
    local lx, ly = sp.x - (ox or 0), sp.y - (oy or 0)
    local wx, wy = px + lx * c - ly * s, py + lx * s + ly * c
    local heading = (sp.yaw or 0) + yaw
    local rot = quatFromDir(vec3(cos(heading), sin(heading), 0), UP)
    out[#out + 1] = {
      pos = { wx, wy, groundZ and groundZ(wx, wy) or 0 },
      rot = { rot.x, rot.y, rot.z, rot.w },
      scl = { sp.w, sp.d, SPOT_H },
      isMultiSpot = (sp.n or 1) > 1,
      spotAmount = sp.n or 1,
      spotOffset = 0, -- bays are packed edge to edge, so centre-to-centre spacing is the bay width
      spotDirection = sp.dir or 'Right',
      spotRotation = 0,
      color = { 1, 1, 1 },
      customFields = { names = {}, types = {}, values = {}, tags = {} },
    }
  end
  return out
end


local function sitesPath()
  local dir = path.split(getMissionFilename())
  if not dir then return nil end
  return dir .. 'city.sites.json'
end

local function emptySites()
  return { name = 'sites', description = '', locations = {}, zones = {}, parkingSpots = {} }
end

--- Add spots to the level's sites file, under names starting with `prefix`.
---
--- Added rather than replacing whatever was there: burning is a one-way handover, so a second burn has to stand beside the
--- first rather than on top of it. Names and ids carry on past whatever the file already holds, so two burns and a
--- hand-authored spot can share the file without colliding.
---
--- Answers what an undo needs -- the array exactly as it was -- or nothing when there was nothing to add.
local function write(spots, prefix)
  local n = #(spots or {})
  if n == 0 then return nil end
  local p = sitesPath()
  if not p then return nil end

  local data = FS:fileExists(p) and jsonReadFile(p) or nil
  if type(data) ~= 'table' then data = emptySites() end
  data.parkingSpots = data.parkingSpots or {}
  local prev = deepcopy(data.parkingSpots)

  local taken, maxId = {}, 0
  for i = 1, #prev do
    local ps = prev[i]
    if type(ps) == 'table' then
      if type(ps.name) == 'string' then taken[ps.name] = true end
      if type(ps.oldId) == 'number' and ps.oldId > maxId then maxId = ps.oldId end
    end
  end

  local seq = 0
  for i = 1, n do
    local ps = spots[i]
    repeat
      seq = seq + 1
      ps.name = prefix .. seq
    until not taken[ps.name]
    taken[ps.name] = true
    maxId = maxId + 1
    ps.oldId = maxId
    data.parkingSpots[#data.parkingSpots + 1] = ps
  end
  jsonWriteFile(p, data, true)
  return { path = p, prev = prev }
end

--- Undo a write: put the array back exactly as it was.
local function restore(undo)
  if not (undo and undo.path) then return end
  local data = FS:fileExists(undo.path) and jsonReadFile(undo.path) or nil
  if type(data) ~= 'table' then data = emptySites() end
  data.parkingSpots = undo.prev or {}
  jsonWriteFile(undo.path, data, true)
end


-- Public interface.
M.SPOT_H = SPOT_H

M.localise = localise
M.place = place
M.write = write
M.restore = restore

return M