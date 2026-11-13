-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Road markings as a site carries them: bay lines, hatching, give-way bars, aisle centre lines, tyre wear, cracks and
-- zebras. Every one is a DecalRoad, which is a thing painted ONTO the ground rather than a piece of geometry standing on
-- it -- so none of it can go into a shell, and a baked car park has to carry what to paint and paint it again where it
-- is put down. The same arrangement the water uses, for the same reason.

local M = {}

-- Module constants.
local floor, cos, sin = math.floor, math.cos, math.sin
local MM = 1000


local function round3(v) return floor(v * MM + 0.5) / MM end

--- One DecalRoad, from the record that describes it.
local function emit(folder, rec, terrainZ)
  local pts = rec.pts
  local n = #(pts or {})
  if n < 2 then return nil end
  local d = createObject('DecalRoad')
  if not d then return nil end
  d.canSave = false
  d:registerObject('')
  folder:addObject(d)
  d:setField('improvedSpline', 0, 'true')
  d:setField('overObjects', 0, rec.over and 'true' or 'false')
  d:setField('material', 0, rec.mat)
  d:setField('textureLength', 0, tostring(rec.texLen))
  d:setField('renderPriority', 0, tostring(rec.prio))
  d:setField('drivability', 0, '-1')
  d:setField('startEndFade', 0, rec.fade and string.format('%f %f', rec.fade[1], rec.fade[2]) or '0 0')
  local w = rec.width
  local perNode = type(w) == 'table'
  local lift = rec.lift or 0
  local flat = rec.z -- a mark on a slab is laid at the slab, not at the terrain that happens to be under it
  local function nodeZ(p) return (flat or terrainZ(p.x, p.y)) + lift end
  for i = 1, n do
    local p = pts[i]
    d:insertNodeNoRegen(vec3(p.x, p.y, nodeZ(p)), perNode and (w[i] or w[1]) or w, i - 1)
  end
  if rec.closed then
    local p = pts[1]
    d:insertNodeNoRegen(vec3(p.x, p.y, nodeZ(p)), perNode and w[1] or w, n)
  end
  d:regenerate()
  return d
end

--- A whole plan painted at once. Answers the objects made, so whoever asked can hand them over or take them down again.
local function build(plan, folder, terrainZ)
  local out = {}
  if not (plan and folder) then return out end
  for i = 1, #plan do
    local d = emit(folder, plan[i], terrainZ)
    if d then out[#out + 1] = d end
  end
  return out
end

--- Hand the marks to the level. Painted by the tool they belong to nothing and are not written out; from here they are the
--- level's own, and the tool must not delete them.
local function commit(objs)
  for i = 1, #(objs or {}) do
    local o = objs[i]
    if o and simObjectExists(o) then
      o.canSave = true
      o.cansave = true
    end
  end
end


--- The plan as a manifest carries it, local to the bake origin.
---
--- Grouped by style, because a lot paints a thousand marks in about four of them -- one for the white bay grid, one for the
--- yellow reserved boxes, one for the hatching, one for the give-way bars. Saying which of the four each run is in costs an
--- index where saying it in full would cost five fields a thousand times over.
local function localise(plan, ox, oy, oz)
  if not (plan and #plan > 0) then return nil end
  local styles, byKey, runs = {}, {}, {}
  for i = 1, #plan do
    local m = plan[i]
    local pts = m.pts
    if pts and #pts >= 2 then
      -- A tapering mark's widths belong to the run, not to the style: two runs of wear that thin differently are the same
      -- paint and should not be two styles for it.
      local perNode = type(m.width) == 'table'
      -- The slab height joins the style rather than the run for the same reason the lift already has: every line on one
      -- court shares it, so it is one more field on a handful of styles instead of a number on every run.
      local z = m.z and round3(m.z - (oz or 0)) or nil
      local key = string.format('%s|%s|%s|%s|%s|%s|%s', tostring(m.mat), tostring(m.texLen), tostring(m.prio),
                                tostring(m.lift or 0), perNode and '*' or tostring(m.width), tostring(m.over),
                                tostring(z))
      local s = byKey[key]
      if not s then
        styles[#styles + 1] = { mat = m.mat, texLen = m.texLen, prio = m.prio, lift = m.lift or 0,
                                width = (not perNode) and m.width or nil, over = m.over or nil, z = z }
        s = #styles
        byKey[key] = s
      end
      local flat = {}
      for k = 1, #pts do
        flat[#flat + 1] = round3(pts[k].x - ox)
        flat[#flat + 1] = round3(pts[k].y - oy)
      end
      local rec = { s = s, pts = flat }
      if m.closed then rec.closed = true end
      if m.fade then rec.fade = { m.fade[1], m.fade[2] } end
      if perNode then
        local w = {}
        for k = 1, #m.width do w[k] = m.width[k] end
        rec.w = w
      end
      runs[#runs + 1] = rec
    end
  end
  return (#runs > 0) and { styles = styles, runs = runs } or nil
end

--- And back: the manifest's marks as a plan, stood where a placement is and turned onto its heading.
---
--- `ox, oy` is the point in the site's own frame the placement turns about -- the middle of its footprint rather than the
--- bake origin at a corner. The same two numbers everything else a placement stands is measured off. `pz` is the height
--- the placement sits at, which only the marks laid on one of its own slabs need.
local function place(rec, px, py, yaw, ox, oy, pz)
  if not (rec and rec.runs and rec.styles) then return nil end
  yaw = yaw or 0
  local c, s = cos(yaw), sin(yaw)
  local out = {}
  for i = 1, #rec.runs do
    local r = rec.runs[i]
    local st = rec.styles[r.s]
    local flat = r.pts
    if st and flat and #flat >= 4 then
      local pts = {}
      for k = 1, #flat, 2 do
        local lx, ly = flat[k] - (ox or 0), flat[k + 1] - (oy or 0)
        pts[#pts + 1] = { x = px + lx * c - ly * s, y = py + lx * s + ly * c }
      end
      out[#out + 1] = { mat = st.mat, texLen = st.texLen, prio = st.prio, lift = st.lift, over = st.over,
                        z = st.z and ((pz or 0) + st.z) or nil,
                        width = r.w or st.width, pts = pts, closed = r.closed, fade = r.fade }
    end
  end
  return (#out > 0) and out or nil
end


-- Public interface.
M.emit = emit
M.build = build
M.commit = commit

M.localise = localise
M.place = place

return M