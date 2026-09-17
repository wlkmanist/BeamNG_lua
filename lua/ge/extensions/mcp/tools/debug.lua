-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Debug-draw tools: persistent world spheres/lines/text (redrawn each frame) to
-- highlight positions, errors or problems. Shapes live until cleared or their ttl expires.

local shared = require('mcp/shared')
local M = {}

local shapes = {} -- id -> shape descriptor
local nextId = 0

local function toVec(p) return vec3((p and (p.x or p[1])) or 0, (p and (p.y or p[2])) or 0, (p and (p.z or p[3])) or 0) end
local function toColorF(c) c = c or {} return ColorF(c.r or c[1] or 1, c.g or c[2] or 0, c.b or c[3] or 0, c.a or c[4] or 1) end
local function drawLabel(pos, text)
  debugDrawer:drawTextAdvanced(pos, tostring(text), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 255))
end

local function drawShape(s)
  if s.kind == "line" then
    debugDrawer:drawLine(s.from, s.to, s.color)
    if s.label then drawLabel((s.from + s.to) * 0.5, s.label) end
  elseif s.kind == "text" then
    if s.label then drawLabel(s.pos, s.label) end
  else -- sphere
    debugDrawer:drawSphere(s.pos, s.radius, s.color)
    if s.label then drawLabel(s.pos, s.label) end
  end
end

function M.onPreRender(dtReal)
  if not next(shapes) then return end
  local now = os.clockhp()
  for id, s in pairs(shapes) do
    if s.expiry and now > s.expiry then shapes[id] = nil else drawShape(s) end
  end
end

-- Add/replace a persistent debug shape. Returns its id.
function M.debug_draw(args)
  args = args or {}
  local kind = args.kind or (args.from and "line") or "sphere"
  local s = { kind = kind, color = toColorF(args.color), label = args.label or args.text }
  if kind == "line" then
    if not (args.from and args.to) then return "line needs 'from' and 'to' {x,y,z}", true end
    s.from, s.to = toVec(args.from), toVec(args.to)
  else
    if not args.pos then return kind .. " needs 'pos' {x,y,z}", true end
    s.pos = toVec(args.pos)
    s.radius = tonumber(args.radius) or 0.5
    if kind == "text" and not s.label then return "text needs 'label'", true end
  end
  local ttl = tonumber(args.ttl)
  if ttl and ttl > 0 then s.expiry = os.clockhp() + ttl end
  local id = args.id
  if id == nil then nextId = nextId + 1; id = "s" .. nextId end
  shapes[tostring(id)] = s
  return tostring(id), false
end

function M.debug_clear(args)
  local id = args and args.id
  if id ~= nil then shapes[tostring(id)] = nil; return "cleared " .. tostring(id), false end
  shapes = {}
  return "cleared all debug shapes", false
end

M.schemas = {
  debug_draw = {
    description = "Draw a persistent debug shape in the world (redrawn every frame until cleared) to highlight a position/error. kind: 'sphere' (pos+radius), 'line' (from+to), 'text' (pos+label). Optional label, color {r,g,b,a} 0..1 (default red), ttl seconds (0=persistent), id (reuse to move/replace). Returns the shape id.",
    inputSchema = { type = "object", properties = {
      kind = { type = "string", description = "'sphere' (default), 'line', or 'text'" },
      pos = { type = "object", description = "{x,y,z} for sphere/text" },
      from = { type = "object", description = "{x,y,z} line start" },
      to = { type = "object", description = "{x,y,z} line end" },
      radius = { type = "number", description = "Sphere radius in m (default 0.5)" },
      label = { type = "string", description = "Text label drawn at the shape" },
      color = { type = "object", description = "{r,g,b,a} 0..1 (default red {1,0,0,1})" },
      ttl = { type = "number", description = "Seconds before it disappears (0/omitted = persistent)" },
      id = { type = "string", description = "Reuse an id to move/replace an existing shape" },
    } },
  },
  debug_clear = {
    description = "Clear debug shapes: pass an id to clear one, or omit to clear all.",
    inputSchema = { type = "object", properties = { id = { type = "string", description = "Shape id from debug_draw (omit to clear all)" } } },
  },
}

return M
