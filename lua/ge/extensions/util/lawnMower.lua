-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Prop-driven lawn mower (ge-only). Scans each vehicle's parsed jbeam (via core_vehicle_manager) for
-- props tagged with `mowerRadius` and cuts grass into the shared surface mask (owned by
-- util_surfaceMaskWheels) while the deck sits low and flat over grass terrain. No vehicle-side lua.
--
-- Loads itself: a mower part declares `"gameEngineExtensions": {"util_lawnMower": true}` and the jbeam
-- loader loads this extension when that part is installed (also pulls in util_surfaceMaskWheels). Manual
-- extensions.load("util_lawnMower") also works.
--
-- HOW TO USE (jbeam)
-- In the mower part: add `"gameEngineExtensions": {"util_lawnMower": true}` (so it auto-loads), and tag
-- the deck prop in the "props" section with these options in its trailing option dict:
--
--   "props": [
--     ["func", "mesh", "idRef:", "idX:", "idY:", "baseRotation", "rotation", "translation"],
--     ["mower_deck", "deck.dae", "deck_ref", "deck_x", "deck_y", {"x":0,"y":0,"z":0}, {"x":0,"y":0,"z":0}, {"x":0,"y":0,"z":0},
--       {"mowerRadius": 0.9, "mowerGroundDistance": 0.4}],
--   ],
--
-- Options:
--   mowerRadius        (number, meters)  REQUIRED. Presence tags the prop as a mower; value is the cut
--                                        radius of the stamped swath.
--   mowerGroundDistance(number, meters)  Optional (default 0.5). Max height of the deck above the
--                                        terrain at which it still cuts (raise it higher = no cut).
--
-- Notes:
--   * The prop's frame nodes idRef/idX/idY drive it: the swath is centered on their centroid, and the
--     deck only cuts while it is BOTH low (within mowerGroundDistance) AND seated flat (its plane
--     roughly parallel to the terrain, so a raised or folded deck stops cutting).
--   * For raise/fold gating to work, build the deck on real physical nodes (so idRef/idX/idY move when
--     it lifts). A purely cosmetic prop animation won't be detected.
--   * Grass clippings only fly over grass terrain materials (name contains "grass") and only the first
--     time a spot is cut. Only the player vehicle and mowers near it (within the clipmap window) cut.

local M = {}

M.dependencies = { "util_surfaceMaskWheels", "core_vehicle_manager" } -- mask service + parsed vehicle data
M.enabled = false

local updateInterval = 0.05
local flattenStrength = 1
local markStrength = 1      -- mow strength written into the mask
local groundDistance = 0.5 -- default max height (m) of a deck's base node above terrain to still cut
local deckAlignDot = 0.85  -- min |deck normal . terrain normal| (~cos 31deg) to count as seated flat (vs folded/raised)
local normalSampleDelta = 0.75 -- m; spacing for the finite-difference terrain normal (avoids a getNormal vec3 alloc)
local minMoveSq = 0.04
local maxMoveSq = 100
local cellSize = 0.5        -- world cell size (m); clippings only fly the first time a cell is cut
local grassParticleType = 21
local grassParticleCount = 3
local particleWidth = 0.3

local timer = 0
-- mower props per vehicle id, scanned from the parsed jbeam on spawn:
-- mowers[id] = { {node=cid, x=cid?, y=cid?, radius=r, groundDist=d?}, ... }. mowerPrev holds the
-- per-mower swath history (vec3 last stamp, or false = lifted off ground so next contact restarts).
local mowers = {}
local mowerPrev = {}
-- freshly-mown-cell set (mownCells[cellX][cellY] = true) so clippings only fly on the first cut of a
-- spot; grassMatCache maps a terrain material index -> "is grass" so we type/gate emission without a
-- string lookup every tick. Both reset on level change (terrain materials + mask are per level).
local mownCells = {}
local grassMatCache = {}
local terrainObj = nil       -- cached terrain object (per level) so we don't re-resolve it every tick
local scratchGround = vec3() -- reused terrain query, no per-tick alloc

-- Is the deck (its plane normal dnx/dny/dnz, computed by the caller from the frame nodes) seated flat
-- against the ground? The terrain normal is taken from central height differences (getHeight returns
-- plain numbers) instead of terrain:getNormal, which would allocate a vec3 every tick. Normal-based,
-- so it's slope-invariant; all-number math, zero garbage. |dot| is winding-agnostic.
local function alignedWithTerrain(terrain, cx, cy, dnx, dny, dnz)
  local dlen = math.sqrt(dnx * dnx + dny * dny + dnz * dnz)
  if dlen < 1e-6 then return true end -- degenerate frame: don't block
  scratchGround:set(cx - normalSampleDelta, cy, 0); local hl = terrain:getHeight(scratchGround)
  scratchGround:set(cx + normalSampleDelta, cy, 0); local hr = terrain:getHeight(scratchGround)
  scratchGround:set(cx, cy - normalSampleDelta, 0); local hd = terrain:getHeight(scratchGround)
  scratchGround:set(cx, cy + normalSampleDelta, 0); local hu = terrain:getHeight(scratchGround)
  local tnx, tny, tnz = hl - hr, hd - hu, 2 * normalSampleDelta
  local tlen = math.sqrt(tnx * tnx + tny * tny + tnz * tnz)
  if tlen < 1e-6 then return true end
  return math.abs(dnx * tnx + dny * tny + dnz * tnz) / (dlen * tlen) >= deckAlignDot
end

-- Throw grass clippings, but only the first time a world cell is cut and only over a grass terrain
-- material (no puffs on dirt/road or on already-mown ground). This is our stand-in for "how much /
-- what was mowed": the mask lives on the gpu and can't be read back cheaply.
local function emitClippings(veh, wx, wy, wz, terrain)
  if not terrain then return end
  local cellX = math.floor(wx / cellSize)
  local cellY = math.floor(wy / cellSize)
  local row = mownCells[cellX]
  if row and row[cellY] then return end -- already cut here: nothing left to throw

  scratchGround:set(wx, wy, 0)
  local matIdx = terrain:getMaterialIdxWs(scratchGround)
  local isGrass = grassMatCache[matIdx]
  if isGrass == nil then
    local name = terrain:getMaterialName(matIdx) or ""
    isGrass = string.find(string.lower(name), "grass") ~= nil -- heuristic; adjust to your grass layer names
    grassMatCache[matIdx] = isGrass
  end

  if not row then row = {}; mownCells[cellX] = row end
  row[cellY] = true -- mark cut regardless, so each cell is tested only once
  if not isGrass then return end

  -- spawn straight into the vehicle's particle stream from ge (nodeid -1 = world pos), no vm round-trip
  veh:queueParticleWorld(wx, wy, wz, particleWidth, grassParticleCount, grassParticleType)
end

-- Mask a swath under the center of each tagged prop's frame, but only while the deck is low AND
-- seated flat to the terrain. Node world positions are read live (getNodeAbsPositionXYZ), so terrain
-- undulation, a raised deck and a folded/tilted deck (normal swung off the ground) all gate the cut.
local function updateMowers(veh, list, terrain)
  local id = veh:getID()
  local prev = mowerPrev[id]
  if not prev then prev = {}; mowerPrev[id] = prev end

  for i = 1, #list do
    local m = list[i]
    -- stamp at the center of the prop's frame nodes (idRef/idX/idY) rather than the corner ref node,
    -- so the swath sits under the middle of the deck; fall back to the ref node if x/y are missing.
    local rx, ry, rz = veh:getNodeAbsPositionXYZ(m.node)
    local cx, cy, cz, seated = rx, ry, rz, true
    if m.x and m.y then
      local xx, xy, xz = veh:getNodeAbsPositionXYZ(m.x)
      local yx, yy, yz = veh:getNodeAbsPositionXYZ(m.y)
      cx, cy, cz = (rx + xx + yx) / 3, (ry + xy + yy) / 3, (rz + xz + yz) / 3
      -- deck plane normal = (idX - idRef) x (idY - idRef)
      local e1x, e1y, e1z = xx - rx, xy - ry, xz - rz
      local e2x, e2y, e2z = yx - rx, yy - ry, yz - rz
      seated = alignedWithTerrain(terrain, cx, cy, e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x)
    end
    scratchGround:set(cx, cy, cz)
    -- cut only when the deck is both low (center near terrain) and seated flat (its plane roughly
    -- parallel to the ground); the flatness test is normal-based, so slopes are handled correctly.
    local grounded = (cz - terrain:getHeight(scratchGround)) <= (m.groundDist or groundDistance) and seated
    if grounded then
      local p = prev[i]
      if not p then
        util_surfaceMaskWheels.maskCircleWorld(cx, cy, m.radius, flattenStrength, markStrength)
        emitClippings(veh, cx, cy, cz, terrain)
        prev[i] = vec3(cx, cy, cz) -- one-time alloc per mower on first contact
      else
        local dx, dy = cx - p.x, cy - p.y
        local moveSq = dx * dx + dy * dy
        if moveSq > maxMoveSq then
          p:set(cx, cy, cz) -- teleport: don't streak a line across the world
        elseif moveSq > minMoveSq then
          util_surfaceMaskWheels.maskLineWorld(p.x, p.y, cx, cy, m.radius * 2, flattenStrength, markStrength)
          emitClippings(veh, cx, cy, cz, terrain)
          p:set(cx, cy, cz)
        end
      end
    else
      prev[i] = false -- lifted/off ground: break the swath, next contact starts a fresh circle
    end
  end
end

function M.onPreRender(dtReal, dtSim)
  if not M.enabled then return end
  if not next(mowers) then return end -- no mower-equipped vehicles anywhere
  if not util_surfaceMaskWheels or not util_surfaceMaskWheels.isReady() then return end

  timer = timer + (dtSim or dtReal or 0)
  if timer < updateInterval then return end
  timer = timer % updateInterval

  terrainObj = terrainObj or (core_terrain and core_terrain.getTerrain and core_terrain.getTerrain())
  if not terrainObj then return end

  -- One shared clipmap window: center on the player (fallback to any mower), matching
  -- util_surfaceMaskWheels so the two don't fight over the window. Every mower vehicle within the
  -- resident window then cuts together; any farther than the window get dropped by the clipmap.
  local anchor = be and be:getPlayerVehicle(0)
  local centered = false
  if anchor then
    local ax, ay = anchor:getPositionXYZ()
    util_surfaceMaskWheels.setCenter(ax, ay)
    centered = true
  end

  for vehId, list in pairs(mowers) do
    local veh = getObjectByID(vehId)
    if veh then
      if not centered then
        local ax, ay = veh:getPositionXYZ()
        util_surfaceMaskWheels.setCenter(ax, ay)
        centered = true
      end
      updateMowers(veh, list, terrainObj)
    else
      mowers[vehId] = nil -- vehicle gone (deleted/replaced): drop stale state so it can't leak
      mowerPrev[vehId] = nil
    end
  end
end

-- Scan a vehicle's parsed jbeam props (ge-side, via core_vehicle_manager) for ones tagged with
-- mowerRadius and store their resolved frame node cids. Runs on spawn and on part change (re-spawn),
-- so it also clears the entry when a config no longer has a mower deck. idRef/idX/idY are already
-- resolved to cids in vdata (jbeam props processing does tonumber() on them).
local function scanVehicle(vehId)
  local vd = core_vehicle_manager and core_vehicle_manager.getVehicleData(vehId)
  local props = vd and vd.vdata and vd.vdata.props
  local list
  if props then
    for _, prop in pairs(props) do
      if prop.mowerRadius and prop.idRef then
        list = list or {}
        list[#list + 1] = {
          node = tonumber(prop.idRef),
          x = tonumber(prop.idX),
          y = tonumber(prop.idY),
          radius = tonumber(prop.mowerRadius) or 1,
          groundDist = tonumber(prop.mowerGroundDistance),
        }
      end
    end
  end
  mowers[vehId] = list                  -- nil when none: clears any prior entry (e.g. deck removed)
  mowerPrev[vehId] = list and {} or nil -- reset swath history on (re)scan
end

function M.onVehicleSpawned(vehId)
  scanVehicle(vehId)
end

function M.onClientStartMission()
  mownCells = {}     -- new level: fresh terrain, so re-mow throws clippings again
  grassMatCache = {} -- terrain material indices are per-level
  terrainObj = nil   -- re-resolve the terrain object for the new level
end

function M.onVehicleDestroyed(vehId)
  mowers[vehId] = nil
  mowerPrev[vehId] = nil
end

function M.onExtensionLoaded()
  M.enabled = true
  for _, veh in ipairs(getAllVehicles()) do -- pick up vehicles that spawned before we were loaded
    scanVehicle(veh:getID())
  end
end

function M.setEnabled(enabled)
  M.enabled = enabled and true or false
  timer = 0
end

function M.toggle()
  M.setEnabled(not M.enabled)
end

function M.onSerialize()
  return { enabled = M.enabled }
end

function M.onDeserialized(data)
  if not data then return end
  M.enabled = data.enabled and true or false
end

return M
