-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Floating player name tags via the Skia mptag billboard system (same toolchain as license
-- plates): one camera-facing billboard per player, tinted to their colour, following their car.
-- Shared by splitscreen and multiseat. Each tag can be hidden in a set of views (e.g. a player's
-- own split-screen view, so they don't see their own tag) while showing in every other view.

require("utils")
local M = {}

local TAG_TEMPLATE = "art/sktemplates/multiplayer-nametag.sktemplate.json"
local tagRenderer, tagDesign
local playerTags = {} -- player -> billboard id

local palette = {
  {0.95, 0.10, 0.10}, -- red
  {0.15, 0.45, 1.00}, -- blue
  {1.00, 0.85, 0.05}, -- yellow
  {0.15, 0.75, 0.20}, -- green
  {1.00, 0.20, 0.90}, -- magenta
  {0.10, 0.85, 0.95}, -- cyan
  {1.00, 0.50, 0.00}, -- orange
  {0.60, 0.25, 0.95}, -- purple
  {1.00, 0.55, 0.75}, -- pink
  {0.65, 0.90, 0.10}, -- lime
  {1.00, 1.00, 1.00}, -- white
  {0.45, 0.25, 0.10}, -- brown
}

-- fallback for more players than the palette: spread the leftover hues around the wheel
local function hueColor(h)
  local f, seg = h * 6 - math.floor(h * 6), math.floor(h * 6) % 6
  if seg == 0 then return {1, f, 0} end
  if seg == 1 then return {1 - f, 1, 0} end
  if seg == 2 then return {0, 1, f} end
  if seg == 3 then return {0, 1 - f, 1} end
  if seg == 4 then return {f, 0, 1} end
  return {1, 0, 1 - f}
end

-- colour for the idx-th player (1-based) out of n players
function M.color(idx, n)
  return palette[idx] or hueColor((idx - 1) / math.max(1, n))
end

local function chan(x) x = math.floor((x or 0) * 255 + 0.5); return x < 0 and 0 or (x > 255 and 255 or x) end
local function rgbHex(rgb) return string.format("#%02x%02x%02x", chan(rgb[1]), chan(rgb[2]), chan(rgb[3])) end

local function ensureTagRenderer()
  if tagRenderer and tagRenderer.create then return tagRenderer end
  if scenetree and scenetree.playerNameTags then tagRenderer = scenetree.playerNameTags; return tagRenderer end
  if not (WorldBillboardRenderer and scenetree and scenetree.MissionGroup) then return nil end
  local r = WorldBillboardRenderer()
  if not r then return nil end
  r:registerObject("playerNameTags")
  scenetree.MissionGroup:addObject(r)
  tagRenderer = r
  return r
end

-- paint every node tagged role="accent" (the side bar + status dot) with the player's colour
local function tintAccent(node, hex)
  if type(node) ~= "table" then return end
  if node.role == "accent" then node.color = hex end
  if node.children then for _, c in ipairs(node.children) do tintAccent(c, hex) end end
end

-- resolved mptag template tinted to the player's colour, with their label baked in
local function buildTagTemplate(name, rgb)
  if not tagDesign then tagDesign = jsonReadFile(TAG_TEMPLATE) end
  if not extensions.core_skiaTemplate then extensions.load("core_skiaTemplate") end
  local st = extensions.core_skiaTemplate
  if type(tagDesign) ~= "table" or not st then return nil end
  local d = deepcopy(tagDesign)
  tintAccent(d.root, rgbHex(rgb))
  return st.resolveTemplate(d, {name = name, distance = ""})
end

local function destroy()
  if tagRenderer then
    for _, id in pairs(playerTags) do pcall(function() tagRenderer:destroy(id) end) end
  end
  playerTags = {}
end
M.destroy = destroy

-- drop the renderer reference (e.g. before a GE/Lua reload tears down the C++ object)
function M.reset()
  destroy()
  tagRenderer = nil
end

function M.rebuild(tags)
  destroy()
  local r = ensureTagRenderer()
  if not r then return end
  for _, t in ipairs(tags) do
    local resolved = buildTagTemplate(t.label, t.color)
    if resolved then
      local id = r:create(jsonEncode(resolved), false) -- static texture, rendered once
      if id and id ~= 0 then
        r:render(id, "{}")
        if t.hideInViews then r:setViewFilter(id, t.hideInViews, false) end -- blacklist these views
        playerTags[t.player] = id
      end
    end
  end
end

local TAG_STACK = 0.55 -- vertical gap (m) between stacked co-driver tags
function M.updatePositions()
  if not tagRenderer then return end
  local byVeh = {} -- vehId -> sorted list of {player, id} sharing that vehicle
  for player, id in pairs(playerTags) do
    local veh = getPlayerVehicle(player)
    if veh then
      local g = byVeh[veh:getID()]
      if not g then g = {veh = veh, occupants = {}}; byVeh[veh:getID()] = g end
      table.insert(g.occupants, {player = player, id = id})
    else
      tagRenderer:update(id, vec3(0, 0, 0), 0.7, false) -- no vehicle: hide
    end
  end
  for _, g in pairs(byVeh) do
    table.sort(g.occupants, function(a, b) return a.player < b.player end) -- stable top-to-bottom order
    local base = g.veh:getPosition() + vec3(0, 0, 2.2)
    local n = #g.occupants
    for i, o in ipairs(g.occupants) do
      tagRenderer:update(o.id, base + vec3(0, 0, (n - i) * TAG_STACK), 0.7, true) -- lowest player on top
    end
  end
end

return M
