-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- AI tools: get/set a vehicle's AI controls (mode, speed, aggression, target, ...).

local shared = require('mcp/shared')
local M = {}

-- Vehicle-VM snippet: snapshot AI controls and send them back to GE as _cb.ai.
local AI_GET_CMD = [[local s=ai and {mode=ai.mode,speedMode=ai.speedMode,routeSpeed=ai.routeSpeed,aggression=ai.extAggression,targetObjectID=ai.targetObjectID,avoidCars=ai.extAvoidCars} or {error="ai not loaded"} obj:queueGameEngineLua("extensions.mcp_tools._cb.ai("..obj:getId()..","..string.format("%q", jsonEncode(s))..")")]]

M.cb = {
  ai = function(vid, json) shared.asyncResults.ai = json end,
}

-- Get a vehicle's AI controls. Async (vehicle VM -> GE); pair with set_ai.
function M.get_ai(args)
  local vid = shared.argVehId(args)
  if not getObjectByID(vid) then return "no vehicle " .. tostring(vid), true end
  local prev = shared.asyncResults.ai
  shared.asyncResults.ai = nil
  be:queueObjectLua(vid, AI_GET_CMD)
  if prev then return prev, false end
  return "ai state requested (async); call again in a moment", false
end

-- Set a vehicle's AI controls (accepts the keys returned by get_ai).
function M.set_ai(args)
  args = args or {}
  local vid = shared.argVehId(args)
  if not getObjectByID(vid) then return "no vehicle " .. tostring(vid), true end
  local st = {}
  if args.mode ~= nil then st.mode = args.mode end
  if args.speedMode ~= nil then st.speedMode = args.speedMode end
  if args.routeSpeed ~= nil then st.routeSpeed = args.routeSpeed end
  if args.aggression ~= nil then st.extAggression = args.aggression end
  if args.targetObjectID ~= nil then st.targetObjectID = args.targetObjectID end
  if args.avoidCars ~= nil then st.extAvoidCars = args.avoidCars end
  if next(st) == nil then return "nothing to set (mode/speedMode/routeSpeed/aggression/targetObjectID/avoidCars)", true end
  be:queueObjectLua(vid, "if ai then ai.setState(" .. serialize(st) .. ") end")
  return "set ai on vehicle " .. vid .. ": " .. jsonEncode(st), false
end

-- Send a vehicle's AI to a location: drive to a world 'pos' (snapped to the nearest
-- navgraph node), a named 'waypoint' node, or another vehicle's current position ('targetId').
-- Defaults to the player vehicle; the AI takes over driving until it arrives (or mode is changed).
function M.drive_to(args)
  args = args or {}
  local vid = shared.argVehId(args)
  if not getObjectByID(vid) then return "no vehicle " .. tostring(vid), true end

  local wp, targetPos = args.waypoint
  if not wp then
    if args.pos then targetPos = vec3(args.pos.x, args.pos.y, args.pos.z or 0)
    elseif args.targetId then local o = getObjectByID(args.targetId); targetPos = o and o:getPosition() end
    if not targetPos then return "provide 'pos' {x,y,z}, 'waypoint' (node name), or 'targetId'", true end
    wp = map.findClosestRoad(targetPos)
    if not wp then return "no navgraph node near the target (no roads nearby)", true end
  end

  local p = { wpTargetList = { wp }, avoidCars = args.avoidCars or 'on' }
  if args.routeSpeed ~= nil then p.routeSpeed = args.routeSpeed; p.routeSpeedMode = args.routeSpeedMode or 'limit' end
  if args.aggression ~= nil then p.aggression = args.aggression end
  if args.driveInLane ~= nil then p.driveInLane = args.driveInLane end

  be:queueObjectLua(vid, "if ai then ai.driveUsingPath(" .. serialize(p) .. ") end")
  local msg = "vehicle " .. vid .. " driving to node " .. wp
  if targetPos then msg = msg .. string.format(" (nearest to %.1f, %.1f, %.1f)", targetPos.x, targetPos.y, targetPos.z) end
  return msg, false
end

-- Get the AI navgraph (road network used by AI & traffic). The full graph is huge
-- (thousands of nodes), so this returns summary stats plus the nodes near a point
-- (default: the player vehicle); pass all=true to dump everything (capped by maxNodes).
function M.get_navgraph(args)
  args = args or {}
  local g = map.getMap()
  local nodes = g and g.nodes
  if not nodes or not next(nodes) then return "navgraph not loaded (no level / no roads)", true end

  local nodeCount, edgeCount = 0, 0
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  for _, n in pairs(nodes) do
    nodeCount = nodeCount + 1
    local p = n.pos
    if p then
      if p.x < minx then minx = p.x end
      if p.x > maxx then maxx = p.x end
      if p.y < miny then miny = p.y end
      if p.y > maxy then maxy = p.y end
    end
    for _ in pairs(n.links or {}) do edgeCount = edgeCount + 1 end
  end
  local out = {
    nodeCount = nodeCount,
    linkCount = edgeCount, -- directed links (each node->node entry counted once)
    bbox = { min = { x = minx, y = miny }, max = { x = maxx, y = maxy } },
  }

  if args.near ~= nil or args.radius ~= nil or args.all == true then
    local center
    if args.near then center = vec3(args.near.x, args.near.y, args.near.z or 0)
    else local v = be:getPlayerVehicle(0); center = v and v:getPosition() or (core_camera and core_camera.getPosition()) end
    local r2 = (tonumber(args.radius) or 100) ^ 2
    local maxNodes = tonumber(args.maxNodes) or 300
    local list = {}
    for name, n in pairs(nodes) do
      local p = n.pos
      if args.all == true or (center and p and center:squaredDistance(p) <= r2) then
        local links = {}
        for to, e in pairs(n.links or {}) do
          local tp = nodes[to] and nodes[to].pos
          links[#links + 1] = { to = to, drivability = e.drivability, oneWay = e.oneWay or false, speedLimit = e.speedLimit, len = (tp and p) and (p - tp):length() or nil }
        end
        list[#list + 1] = { name = name, pos = { x = p.x, y = p.y, z = p.z }, radius = n.radius, links = links }
        if #list >= maxNodes then break end
      end
    end
    out.returned = #list
    out.nodes = list
    if center then
      out.center = { x = center.x, y = center.y, z = center.z }
      local n1, n2, dist = map.findClosestRoad(center)
      if n1 then out.closestRoad = { from = n1, to = n2, dist = dist } end
    end
  end

  return jsonEncode(out), false
end

M.schemas = {
  get_ai = {
    description = "Get a vehicle's AI controls (mode, speedMode, routeSpeed, aggression, targetObjectID, avoidCars) as JSON. Async: call again in a moment. Pair with set_ai.",
    inputSchema = { type = "object", properties = shared.vehIdProp },
  },
  set_ai = {
    description = "Set a vehicle's AI controls. Any of: mode ('disabled'/'random'/'span'/'manual'/'chase'/'flee'/'stop'/'follow'/'traffic'/'script'), speedMode ('set'/'limit'/'legal'/'off'), routeSpeed (m/s), aggression (~0.3 calm .. 1 aggressive), targetObjectID, avoidCars ('on'/'off'). Accepts the keys from get_ai.",
    inputSchema = { type = "object", properties = {
      mode = { type = "string" }, speedMode = { type = "string" }, routeSpeed = { type = "number" },
      aggression = { type = "number" }, targetObjectID = { type = "integer" }, avoidCars = { type = "string" }, id = shared.vehIdProp.id,
    } },
  },
  drive_to = {
    description = "Send a vehicle's AI to drive to a location: 'pos' {x,y,z} (snapped to the nearest navgraph node), a named 'waypoint' node, or another vehicle's position via 'targetId'. Defaults to the player vehicle (id). Options: routeSpeed (m/s) with routeSpeedMode ('limit'/'set'), aggression (0.3 calm..1), avoidCars ('on'/'off', default 'on'), driveInLane ('on'/'off'). The AI drives until it arrives; use set_ai mode 'disabled' to hand control back.",
    inputSchema = { type = "object", properties = {
      pos = { type = "object", description = "{x,y,z} target world position" },
      waypoint = { type = "string", description = "Navgraph node name to drive to (overrides pos)" },
      targetId = { type = "integer", description = "Drive to this vehicle/object's current position" },
      routeSpeed = { type = "number", description = "Target speed in m/s" },
      routeSpeedMode = { type = "string", description = "'limit' (cap) or 'set' (hold). Default 'limit' when routeSpeed given" },
      aggression = { type = "number", description = "0.3 (calm) .. 1 (race)" },
      avoidCars = { type = "string", description = "'on'/'off' (default 'on')" },
      driveInLane = { type = "string", description = "'on'/'off' keep to the legal lane" },
      id = shared.vehIdProp.id,
    } },
  },
  get_navgraph = {
    description = "Get the AI navgraph (road network used by AI & traffic): always returns summary stats (nodeCount, linkCount, bbox). Pass 'near' {x,y,z} (default: player vehicle) with 'radius' to also get nearby nodes with their links (to, drivability, oneWay, speedLimit, len) and the closest road; or all=true to dump the whole graph (capped by maxNodes).",
    inputSchema = { type = "object", properties = {
      near = { type = "object", description = "{x,y,z} center for the node query (default: player vehicle position)" },
      radius = { type = "number", description = "Include nodes within this many meters of 'near' (default 100)" },
      all = { type = "boolean", description = "Dump all nodes (ignores near/radius), capped by maxNodes" },
      maxNodes = { type = "integer", description = "Max nodes to return (default 300)" },
    } },
  },
}

return M
