-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The light a site's fittings actually throw: one place that turns a light RECORD into a scene object, for every tool in the
-- suite. Every light is a night light from the moment it stands, so what a tool shows is what the level does after the burn:
-- dark by day, lit after dusk, switched by the environment.

local M = {}

-- Module constants.
local abs = math.abs
local settleMs = 250 -- the environment's rescan walks the whole scene, so it waits until the edits stop
local followMs = 500 -- how often the lights the environment has not scanned are checked against its day and night

-- What a fitting burns. Named rather than given as numbers at each call site so a square and a car park standing next to
-- each other are lit the same colour.
local TONES = {
  warm = { 1.00, 0.72, 0.34 },  -- sodium
  white = { 1.00, 0.95, 0.88 },
  cool = { 0.78, 0.87, 1.00 },  -- metal halide
}
local WHITE = { 1, 1, 1 }

-- Module state.
local owed, owedTimer = false, nil -- a rescan of the whole scene
local fresh = {}                   -- objects spawned or lit since the last flush
local mine = {}                    -- every one of those since the last rescan, which the environment's own switching misses
local mineNight, followTimer = false, nil
local envBehind = false            -- night by the clock but nothing switched, at the last check

--- One object put the way the environment's own pass puts its lights: a lamp switched, a lit lens burning its night colour
--- or dark glass.
local function setNight(obj, night)
  if obj.isSubClassOf and obj:isSubClassOf('LightBase') then
    if obj.setLightEnabled then obj:setLightEnabled(night) end
    return
  end
  local col = night and (obj:getField('nightEmissiveColor', 0) or '') or '0 0 0'
  if col == '' then col = '1 1 1' end
  obj:setField('instanceColor', 0, col .. ' 1')
  if obj.updateInstanceRenderData then obj:updateInstanceRenderData() end
end

--- The environment switches night lights off a scan it caches, and that scan walks every static in the level: seconds, on a
--- built-up map. So a light just spawned (or a lit lens just marked) is not handed to it. Given the object, it is set to the
--- environment's day or night here, and kept in step with it until a rescan takes it in. Without one, the cache is
--- rescanned once the edits have settled -- which a light being deleted does not need: the environment skips one that has gone.
local function markDirty(obj)
  if obj then fresh[#fresh + 1] = obj return end
  owed = true
  owedTimer = owedTimer or hptimer()
  owedTimer:stopAndReset()
end

--- Called every frame by each tool that spawns lights. Cheap until something is owed.
local function flush()
  if owed then
    if owedTimer:stop() < settleMs then return end
    if core_environment and core_environment.refreshnightLightsObjects then core_environment.refreshnightLightsObjects() end
    owed = false
    table.clear(fresh)
    table.clear(mine)
    return
  end
  followTimer = followTimer or hptimer()
  if #fresh == 0 and followTimer:stop() < followMs then return end
  followTimer:stopAndReset()
  local st = core_environment and core_environment.getLightState and core_environment.getLightState()
  -- A Lua reload starts the environment with no scan, and it only scans again on a level load or on leaving the editor:
  -- until then it switches nothing at dusk, ours or the level's. Behind on two checks running is that, not a dusk it
  -- has yet to catch up with, which it does the same frame.
  local behind = st ~= nil and st.isNight == true and st.nightLightsActive ~= true
  if behind and envBehind then
    envBehind = false
    markDirty()
    return
  end
  envBehind = behind
  if #fresh == 0 and #mine == 0 then return end
  local night = st ~= nil and st.nightLightsActive == true
  local switched = night ~= mineNight
  mineNight = night
  if #fresh == 0 and not switched then return end
  -- The gone dropped as it goes: a relaid piece deletes its lamps and spawns new ones every time.
  local keep = 0
  for i = 1, #mine do
    local o = mine[i]
    if simObjectExists(o) then
      if switched then setNight(o, night) end
      keep = keep + 1
      mine[keep] = o
    end
  end
  for i = #mine, keep + 1, -1 do mine[i] = nil end
  for i = 1, #fresh do
    local o = fresh[i]
    if simObjectExists(o) then
      setNight(o, night)
      mine[#mine + 1] = o
    end
  end
  table.clear(fresh)
end

--- Point an existing light at a record. `lt` is { px, py, pz, glow or col, brightness, radius } for a bulb, plus
--- { dx, dy, dz, cone } for a flood; the class (PointLight / SpotLight) is fixed at creation, so it has to match.
local function apply(obj, lt)
  local c = lt.glow or lt.col or WHITE
  obj:preApply()
  if lt.dx then
    -- A cone, not a bulb: its reach is `range`, and where it looks comes off the transform.
    local cone = lt.cone or 70
    obj:setField('range', 0, tostring(lt.radius))
    obj:setField('outerAngle', 0, tostring(cone))
    obj:setField('innerAngle', 0, tostring(cone * 0.6))
  else
    obj:setField('radius', 0, tostring(lt.radius))
  end
  obj:setField('brightness', 0, tostring(lt.brightness))
  obj:setField('color', 0, string.format('%f %f %f 1', c[1], c[2], c[3]))
  obj:setField('castShadows', 0, 'false')
  obj:postApply()
  obj:setPosition(vec3(lt.px, lt.py, lt.pz))
  if lt.dx then
    local up = abs(lt.dz) > 0.98 and vec3(0, 1, 0) or vec3(0, 0, 1)
    local q = quatFromDir(vec3(lt.dx, lt.dy, lt.dz), up):toTorqueQuat()
    obj:setField('rotation', 0, q.x .. ' ' .. q.y .. ' ' .. q.z .. ' ' .. q.w)
  end
end

--- One light object for a record. A nil name leaves it unnamed, which registers ~3 ms faster; the environment's dusk pass
--- keys lights by id, so an unnamed one still switches. A record carrying a direction gets a SpotLight, one without gets a PointLight.
--- A record with `always` is lit day and night (a tunnel is dark at noon) and kept out of all day/night switching.
local function spawn(folder, name, lt)
  local stale = name and scenetree.findObject(name)
  if stale then stale:delete() end
  local obj = createObject(lt.dx and 'SpotLight' or 'PointLight')
  if not obj then return nil end
  -- Otherwise left dark and handed to the environment, which is what the shipped street lighting does and what the
  -- fittings' own lenses already do. A site lit at noon reads as a fault.
  local always = lt.always == true
  obj:setField('nightLight', 0, always and '0' or '1')
  obj:setField('isEnabled', 0, always and 'true' or 'false')
  obj:registerObject(name or '')
  obj.canSave = false
  if folder and folder.addObject then folder:addObject(obj.obj) end
  apply(obj, lt)
  if not always then markDirty(obj) end
  return obj
end


-- Public interface.
M.TONES = TONES

M.apply = apply
M.spawn = spawn
M.markDirty = markDirty
M.flush = flush

return M