-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- What the road network has put on the ground, for the tools that have to build up against it.
--
-- A plot squares itself to the way the street runs, a pavement stops at the kerb, and a car park turns its bays to the road
-- it comes off: none of those can be worked out without knowing where the roads are. The network posts that here once and
-- everything else reads it, rather than each tool reaching into the road tool for itself.
--
-- Nothing is published until the network says so, and every reader gets an honest empty answer until then. A level with no
-- roads drawn and a level whose road tool has not loaded yet look the same from here, which is the right answer to give a
-- pavement either way.
--
-- It runs the other way too: a tool that has paved a stretch of verge posts that back, and the network picks it up and
-- stops painting its own edge blend under the slabs. A paver that has worked out where its footways want pedestrian
-- crossings asks for those here as well. Same board, opposite direction, and still neither side knows the other.

local M = {}

-- Module state.
local net = nil      -- what the network answered with, once it was loaded
local footway = {}   -- owner -> { [groupId] = { left = spans, right = spans } }: verges somebody else has paved
local EMPTY = {}


--- The network's side of the board, filled in once as the road tool loads. Everything below is a thin pass to one of these.
--- Fields: roads, groundSegs, surfaces, invalidate, sig, rev, features, heldPastEdge, footwayChanged.
local function provide(t)
  net = t
end

--- Every road the network has laid, as its plan geometry: `id`, `divPoints`, `tangents`, `binormals`. Junction hubs and
--- anything else that is not a road are left out, so a reader never has to know what kinds there are.
local function roads()
  if not net then return EMPTY end
  return net.roads() or EMPTY
end

--- Which of a road's segments lie on the ground, per divPoint segment, rather than on a flying deck or in a tunnel: a bridge's
--- abutments count, the ground being brought up level with the deck there. Nil when all do.
local function groundSegs(road)
  if not (net and net.groundSegs) then return nil end
  return net.groundSegs(road)
end

--- Every stretch of ground the network has surfaced, in plan: the closed rings of carriageway and sealed junction, and the
--- edge lines that bound no area of their own.
local function surfaces()
  if not net then return EMPTY, EMPTY end
  local s, l = net.surfaces()
  return s or EMPTY, l or EMPTY
end

--- Whether a ring lands on any of that. Asked of the network rather than worked out from `surfaces`, because a junction is
--- bounded partly by lines and testing against those is the network's own business.
local function overRoad(ring)
  if not net then return false end
  return net.overRoad(ring) and true or false
end

--- The surfaces are cached, and this is how a tool that has just moved something says so.
local function invalidate()
  if net then net.invalidate() end
end

--- Bumped whenever the network's surfaces change, for a tool that has to notice the road moved under its own ground.
local function sig()
  if not net then return 0 end
  return net.sig() or 0
end

--- Whether what the network answers now is still on its way to being right: not loaded yet, roads and junctions waiting
--- to be rebuilt, which after a load or a Lua reload goes on for many frames, or a node still being dragged. Ground laid
--- against the roads meanwhile is laid against half of them, so a tool doing that waits for this to clear.
local function busy()
  if not net then return true end
  return net.busy ~= nil and net.busy() or false
end

--- Bumped whenever a road or junction is rebuilt, heights and all, for a tool that stands something on a road's surface.
local function rev()
  if not (net and net.rev) then return 0 end
  return net.rev() or 0
end

--- What the network has told the terrain to do: the ground it has graded and the structures it has stood in it.
local function features()
  if not net then return EMPTY, EMPTY end
  local ground, structure = net.features()
  return ground or EMPTY, structure or EMPTY
end

--- How far past a road's surface edge its grade still holds the ground at the road's own height, outranking anything a site
--- lays there. `paved` is for a verge somebody else has posted as footway, where the road keeps no bare shoulder of its own.
local function heldPastEdge(paved)
  if not (net and net.heldPastEdge) then return 0 end
  return net.heldPastEdge(paved) or 0
end


--- Where the network would take a pedestrian crossing, if somebody wanted one: a site on every approach of the junctions
--- that matter, `density` of them kept and `depthM` deep. Each site says which road it is on, where along it, and the two
--- points its band would reach to -- enough for a paver to keep only the ones it has paved both sides of, and no more than
--- that. Sites the road already carries a crossing at are left out, so a caller relaying its own takes those off first.
local function crossingSites(density, depthM)
  if not (net and net.crossingSites) then return EMPTY end
  return net.crossingSites(density, depthM) or EMPTY
end

--- The crossings this owner wants, as the sites above cut down to the ones it will have, in place of whatever it asked for
--- last time. An empty list takes its crossings back off the roads. Crossings placed by hand, or asked for by somebody
--- else, are left where they are. Answers how many were put down and how many were taken off.
local function applyCrossings(owner, list)
  if not (owner and net and net.applyCrossings) then return 0, 0 end
  return net.applyCrossings(owner, list)
end

--- The verges this owner has paved over, as `{ [groupId] = { left = spans, right = spans } }`, replacing whatever it posted
--- before. The network is told at once, because the blend under those slabs is painted terrain and has to be repainted.
local function publishFootway(owner, byGroup)
  if not owner then return end
  footway[owner] = byGroup
  if net and net.footwayChanged then net.footwayChanged() end
end

--- Everything paved on one road's verges, merged across owners. Nil where nobody has paved it, which is what the network
--- reads as "paint the blend right along".
local function footwayFor(groupId)
  local left, right = nil, nil
  for _, byGroup in pairs(footway) do
    local s = byGroup and byGroup[groupId]
    if s then
      if s.left then
        left = left or {}
        for i = 1, #s.left do left[#left + 1] = s.left[i] end
      end
      if s.right then
        right = right or {}
        for i = 1, #s.right do right[#right + 1] = s.right[i] end
      end
    end
  end
  if not (left or right) then return nil end
  return { left = left, right = right }
end


-- Public interface.
M.provide = provide
M.roads = roads
M.groundSegs = groundSegs
M.surfaces = surfaces
M.overRoad = overRoad
M.invalidate = invalidate
M.sig = sig
M.busy = busy
M.rev = rev
M.features = features
M.heldPastEdge = heldPastEdge
M.crossingSites = crossingSites
M.applyCrossings = applyCrossings
M.publishFootway = publishFootway
M.footwayFor = footwayFor

return M