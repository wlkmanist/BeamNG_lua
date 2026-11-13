-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Stamped decals as a site carries them: the flow arrows, the painted EXIT text, the asphalt repair patches. Glyphs off a
-- sheet rather than paint run along a line, which is what separates them from the markings in siteMarks -- each one is a
-- single cell of an atlas stamped at a point, facing a direction.

local M = {}

-- Module constants.
local floor, cos, sin, atan2 = math.floor, math.cos, math.sin, math.atan2
local MM = 1000
local upV = vec3(0, 0, 1)

local function round3(v) return floor(v * MM + 0.5) / MM end

--- Get, or make, the DecalData one group of stamps comes off. Named after the site standing it, because burning a site
--- flips its own templates to persistent and must not flip a neighbour's.
local function template(name, spec)
  local t = scenetree.findObject(name)
  if t then return t end
  t = createObject('DecalData')
  if not t then return nil end
  t:setField('material', 0, spec.mat)
  t:setField('frame', 0, tostring(spec.frame or 0))
  t:setField('texRows', 0, tostring(spec.rows or 1))
  t:setField('texCols', 0, tostring(spec.cols or 1))
  t:setField('size', 0, tostring(spec.size or 1))
  t:setField('renderPriority', 0, tostring(spec.prio or 5))
  t:registerObject(name)
  return t
end

--- One stamp, from the record that describes it.
local function emit(tpl, rec, terrainZ)
  local x, y = rec.x, rec.y
  local a = rec.a or 0
  return editor.addDecalInstanceWithTan(vec3(x, y, terrainZ(x, y) + (rec.lift or 0)), upV,
                                        vec3(cos(a), sin(a), 0), tpl, rec.size, rec.frame, 3, 1)
end


--- The stamps as a manifest carries them, local to the bake origin. Grouped by template for the same reason the marks are
--- grouped by style: a lot stamps a few dozen glyphs off two sheets.
---
--- The facing is written down as an angle rather than the direction vector it came in as, so standing the site on a new
--- heading is one addition instead of a rotation per stamp.
local function localise(plan, ox, oy)
  if not (plan and #plan > 0) then return nil end
  local tpls, byKey, items = {}, {}, {}
  for i = 1, #plan do
    local d = plan[i]
    local key = string.format('%s|%s|%s|%s', tostring(d.mat), tostring(d.rows), tostring(d.cols), tostring(d.prio))
    local t = byKey[key]
    if not t then
      tpls[#tpls + 1] = { mat = d.mat, rows = d.rows, cols = d.cols, prio = d.prio, size = d.tplSize }
      t = #tpls
      byKey[key] = t
    end
    items[#items + 1] = { t = t, x = round3(d.x - ox), y = round3(d.y - oy), a = round3(d.a or 0),
                          size = d.size, frame = d.frame, lift = d.lift or 0 }
  end
  return (#items > 0) and { tpls = tpls, items = items } or nil
end

--- And back: the manifest's stamps as a plan, stood where a placement is and turned onto its heading. `ox, oy` is the point
--- in the site's own frame the placement turns about, the same one everything else it stands is measured off.
local function place(rec, px, py, yaw, ox, oy)
  if not (rec and rec.items and rec.tpls) then return nil end
  yaw = yaw or 0
  local c, s = cos(yaw), sin(yaw)
  local out = {}
  for i = 1, #rec.items do
    local d = rec.items[i]
    local t = rec.tpls[d.t]
    if t then
      local lx, ly = d.x - (ox or 0), d.y - (oy or 0)
      out[#out + 1] = { mat = t.mat, rows = t.rows, cols = t.cols, prio = t.prio, tplSize = t.size,
                        x = px + lx * c - ly * s, y = py + lx * s + ly * c, a = (d.a or 0) + yaw,
                        size = d.size, frame = d.frame, lift = d.lift }
    end
  end
  return (#out > 0) and out or nil
end

--- A whole plan stamped at once, making whatever templates it calls for. `tag` names them apart from every other site's.
--- Answers the instances and the template ids, which are two different things to clean up: an instance goes when the site
--- does, a template is shared by all of that site's stamps.
local function build(plan, tag, terrainZ)
  local objs, tplIds, made = {}, {}, {}
  for i = 1, #(plan or {}) do
    local d = plan[i]
    local key = string.format('%s|%s|%s|%s', tostring(d.mat), tostring(d.rows), tostring(d.cols), tostring(d.prio))
    local t = made[key]
    if t == nil then
      t = template(string.format('SiteDecal_%s_%d', tostring(tag), #tplIds + 1), d) or false
      made[key] = t
      if t then tplIds[#tplIds + 1] = t:getId() end
    end
    if t then
      local inst = emit(t, d, terrainZ)
      if inst then objs[#objs + 1] = inst end
    end
  end
  return objs, tplIds
end

--- Take the stamps down again.
local function remove(objs)
  for i = 1, #(objs or {}) do
    if objs[i] then editor.deleteDecalInstance(objs[i]) end
  end
end

--- Hand the templates to the level, which is what makes the stamps off them survive a save. The persistence manager keeps
--- the instances against their template, so marking the few templates dirty writes out all the stamps -- there is nothing
--- per-stamp to flip. Per-site templates are what keeps this from writing out a neighbour's stamps too.
local function commit(tplIds)
  local pm = scenetree.decalPersistMan
  if not pm then return end
  local path = editor.getDecalDataFilePath and editor.getDecalDataFilePath()
  for i = 1, #(tplIds or {}) do
    local t = scenetree.findObjectById(tplIds[i])
    if t and simObjectExists(t) then pm:setDirty(t, path) end
  end
end

--- The facing of a stamp, as an angle, from the direction vector a builder already has.
local function facing(tx, ty) return atan2(ty, tx) end


-- Public interface.
M.template = template
M.emit = emit
M.build = build
M.remove = remove
M.commit = commit
M.facing = facing

M.localise = localise
M.place = place

return M