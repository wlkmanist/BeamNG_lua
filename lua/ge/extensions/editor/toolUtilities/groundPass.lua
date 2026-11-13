-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The one terraform of the ground the editor tools lay things on. The road and rail networks are cut together in ONE pass at one
-- blend, so where a road meets a track the ground is one decision rather than two passes each undoing the other's; the rail
-- formation outranks the roads (PRIO.RAIL), which blend to it. City Builder's site grade lies over that ground as a second pass
-- with its own blend: it comes up before the network pass and goes down again after it, so it is always cut to the ground
-- under it. Every tool's Build calls run() and its Restore restore(), whichever tool it is pressed in.
--
-- A network registers a source: features(out, p) appends its terraform features, each with its priority band. Optional: lift()
-- puts back what it holds on the ground besides the shared carve (its tunnel holes, an older session's own carve), finish() cuts
-- its tunnel holes into the new ground once the site grade is down over it, after() rebuilds what stands on the ground,
-- records() lists its older carve records and hasCarve() says whether lift() has anything to put back.

local M = {}

-- Module dependencies.
local terra = require('editor/terraform/terraform')
local bridges = require('editor/roadNetwork/bridges')
local tunnelTerrain = require('editor/roadNetwork/tunnelTerrain')

-- Module constants.
local floor = math.floor
local logTag = 'groundPass'
local defaults = { doi = 40.0, margin = 10.0, falloff = 2.0, smooth = 5, roughness = 0.0, scale = 0.5,
  abutLen = bridges.embankLenM, abutShoulder = bridges.abutShoulderM }

-- Module state.
local params = { on = true, roads = true, rail = true } -- roads / rail: whether a Build covers that network (by source id)
for k, v in pairs(defaults) do params[k] = v end
local sources = {} -- in the order registered
local sites = nil  -- City Builder's grade: lift(), lay(), busy(), record()
local owner = {}   -- owner.terraBaseline: the network pass's record of the ground it moved
local held = false -- the site grade a `holdSites` pass took up, waiting on laySites()
local holesDue = false -- the last carve's tunnel holes, not cut yet
local natList, natN, natFn = {}, {}, nil -- the last naturalGround: the records it was read off, their sizes, and the lookup


local function register(id, s)
  s.id = id
  for i = 1, #sources do
    if sources[i].id == id then sources[i] = s return end
  end
  sources[#sources + 1] = s
end

local function setSites(s) sites = s end

-- Every network's terraform features, with these settings (the shared ones by default). A network ticked off is left out.
local function features(out, p)
  p = p or params
  for _, s in ipairs(sources) do
    if p[s.id] ~= false then s.features(out, p) end
  end
  return out
end

-- Drops the record when the terrain block is not the one it was cut in: its heights are relative to that block, so read or
-- written back on another they land metres off.
local function checkOwner()
  local bl = owner.terraBaseline
  local tb = extensions.editor_terrainEditor and extensions.editor_terrainEditor.getTerrainBlock()
  if bl and not bl.tbId then
    if tb then
      if bl.level == getMissionFilename() then bl.tbId = tb:getID() else owner.terraBaseline = nil end
    end
  elseif bl and (not tb or bl.tbId ~= tb:getID()) then
    owner.terraBaseline = nil
  end
end

-- The tunnel holes, cut once into the ground as it is left. Not before the site grade: it runs the tunnels' features again
-- over ground already cut, and a portal's edge cells can settle differently there. Each cut replaces the last hole record.
local function cutHoles()
  if not holesDue then return end
  holesDue = false
  for _, s in ipairs(sources) do if s.finish then s.finish() end end
end

-- The network carve (when `carve`), between the site grade coming up and going down again. One undo step. `holdSites` leaves
-- the grade up for laySites() to put down, so a Build cutting the networks again grades the sites once, over the last cut.
local function pass(label, carve, p, laySites, holdSites)
  local relay = sites and (laySites or held or sites.record() ~= nil)
  if relay and sites.busy() then
    log('W', logTag, 'held: the road network is still rebuilding')
    return 0
  end
  local own = editor.history:beginTransaction(label)
  if sites then sites.lift() end
  for _, s in ipairs(sources) do if s.lift then s.lift() end end
  checkOwner()
  terra.restoreBaseline(owner, true)
  terra.resetMask()
  holesDue = false
  local out = carve and features({}, p) or {}
  if #out > 0 then
    local bl = {}
    terra.terraformToQuads(p.doi, p.margin, p.falloff, p.roughness, p.scale, out, floor(p.smooth), nil, terra.PRIO.GROUND, bl)
    tunnelTerrain.fillStrays(bl)
    if (bl.n or 0) > 0 then
      local tb = extensions.editor_terrainEditor.getTerrainBlock()
      bl.tbId, bl.level = tb and tb:getID(), getMissionFilename()
      owner.terraBaseline = bl
    end
    holesDue = true
  end
  for _, s in ipairs(sources) do if s.after then s.after() end end
  if relay then
    held = holdSites == true
    if not held then sites.lay() end
  end
  if not held then cutHoles() end
  if own then editor.history:endTransaction(true) end
  if core_terrain.getTerrain() then be:reloadCollision() end
  return #out
end

-- Terraform the networks (when Terraform is on) and lay the site grade back over them. `p` overrides the shared settings for
-- one run; `laySites` grades the sites even when they were not graded; `holdSites` leaves that to laySites().
local function run(p, laySites, holdSites)
  local q = {}
  for k, v in pairs(params) do q[k] = v end
  for k, v in pairs(p or {}) do q[k] = v end
  return pass('Build Ground', q.on, q, laySites, holdSites)
end

-- Lay the site grade the `holdSites` passes kept up over the ground the last of them cut. One undo step.
local function laySites()
  if not held then return 0 end
  if sites.busy() then
    log('W', logTag, 'held: the road network is still rebuilding')
    cutHoles()
    return 0
  end
  held = false
  local own = editor.history:beginTransaction('Grade Sites')
  local n = sites.lay()
  cutHoles()
  if own then editor.history:endTransaction(true) end
  if core_terrain.getTerrain() then be:reloadCollision() end
  return n
end

-- Put the networks' ground back, and the site grade back over it.
local function restore()
  return pass('Restore Ground', false, params)
end

local function hasCarve()
  checkOwner()
  local bl = owner.terraBaseline
  if bl and (bl.n or 0) > 0 then return true end
  for _, s in ipairs(sources) do
    if s.hasCarve and s.hasCarve() then return true end
  end
  return false
end

-- The ground as it was before every carve, as a lookup `height(x, y)` (terraform.groundBefore). Built again only when the
-- records have changed: off them it reads live terrain, which needs no rebuild.
local function naturalGround()
  checkOwner()
  local list = {}
  list[#list + 1] = owner.terraBaseline
  for _, s in ipairs(sources) do
    for _, r in ipairs(s.records and s.records() or {}) do list[#list + 1] = r end
  end
  list[#list + 1] = sites and sites.record()
  local same = natFn ~= nil and #list == #natList
  for i = 1, same and #list or 0 do
    if list[i] ~= natList[i] or list[i].n ~= natN[i] then same = false break end
  end
  if not same then
    natN = {}
    for i = 1, #list do natN[i] = list[i].n end
    natList, natFn = list, terra.groundBefore(list)
  end
  return natFn
end

-- The settings, kept in each tool's session file.
local function getParams()
  local out = {}
  for k, v in pairs(params) do out[k] = v end
  return out
end

local function applyParams(t)
  if type(t) ~= 'table' then return end
  for k, v in pairs(params) do
    if type(t[k]) == type(v) then params[k] = t[k] end
  end
end

-- The carve record, kept over a Lua reload and in the session files.
local function getRecord()
  checkOwner()
  return owner.terraBaseline
end

local function setRecord(bl)
  local ok = type(bl) == 'table' and type(bl.gx) == 'table' and (bl.n or 0) > 0
  if ok then bl.tbId = nil end -- the block's id is per session; checkOwner matches the record to it by level
  owner.terraBaseline = ok and bl or nil
end

-- A new level: its terrain is not the one the record was cut in.
local function reset() owner.terraBaseline = nil end


-- Public interface.
M.params = params
M.defaults = defaults

M.register = register
M.setSites = setSites
M.features = features
M.run = run
M.laySites = laySites
M.restore = restore
M.hasCarve = hasCarve
M.naturalGround = naturalGround
M.getParams = getParams
M.applyParams = applyParams
M.getRecord = getRecord
M.setRecord = setRecord
M.reset = reset

return M