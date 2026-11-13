-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Ground one tool has taken, for the others to keep off.

local geom = require('editor/toolUtilities/geom')

local M = {}

-- Module constants.
local min, max, huge = math.min, math.max, math.huge

-- Module state.
local claims = {} -- owner -> { margin = m, rings = { ring, ... }, tags = { tag, ... } or nil }
local revision = 0


local function ringBox(ring)
  local x0, y0, x1, y1 = huge, huge, -huge, -huge
  for i = 1, #ring do
    local p = ring[i]
    x0, y0, x1, y1 = min(x0, p.x), min(y0, p.y), max(x1, p.x), max(y1, p.y)
  end
  return x0, y0, x1, y1
end

--- Everything this owner holds, replacing whatever it held before, and how far off it everyone else stops. Rings are taken as
--- given and not copied: a caller that goes on mutating its own outlines has to publish again anyway, which is the same rule
--- its own rebuild follows. `tags`, when given, names what each ring is a copy of, so a tool editing that very thing can
--- leave its own copies out (see `obstructions`).
local function publish(owner, rings, margin, tags)
  if not owner then return end
  local t, fp = {}, (margin or 0) * 7919
  local tg = tags and {} or nil
  local box = { huge, huge, -huge, -huge }
  for i = 1, (rings and #rings or 0) do
    local r = rings[i]
    if r and #r >= 3 then
      t[#t + 1] = r
      if tg then tg[#t] = tags[i] end
      fp = fp + #r * 104729
      for k = 1, #r do fp = fp + r[k].x * 31.7 + r[k].y * 17.3 end
      local x0, y0, x1, y1 = ringBox(r)
      box[1], box[2], box[3], box[4] = min(box[1], x0), min(box[2], y0), max(box[3], x1), max(box[4], y1)
    end
  end
  local was = claims[owner]
  if #t == 0 then
    if was == nil then return end
    claims[owner] = nil
  else
    if was and was.fp == fp then was.tags = tg; return end
    local m = margin or 0
    box[1], box[2], box[3], box[4] = box[1] - m, box[2] - m, box[3] + m, box[4] + m
    claims[owner] = { margin = m, rings = t, fp = fp, box = box, tags = tg }
  end
  revision = revision + 1
end

--- Every other owner's fingerprint and the box its ground covers, margin included: what a tool diffs to find WHERE somebody
--- else's ground moved, rather than only that it did.
local function extents(owner)
  local out = {}
  for k, c in pairs(claims) do
    if k ~= owner then out[k] = { fp = c.fp, box = c.box } end
  end
  return out
end

local function clear(owner) publish(owner, nil) end

--- Every claim except one owner's own, appended to `out`. The exclusion is what lets a tool read this without subtracting its
--- own ground from itself. `flushOnly` keeps only the claims asking for no margin: the ground a surface meets as one.
--- `tags`, when given, gets each ring's tag (false for none) at the ring's index in `out`. A ring tagged 'buried' is ground
--- held over something under it, a tunnel's cover: plants may stand on it.
local function others(out, owner, flushOnly, tags)
  out = out or {}
  for k, c in pairs(claims) do
    if k ~= owner and not (flushOnly and c.margin > 0) then
      for i = 1, #c.rings do
        out[#out + 1] = c.rings[i]
        if tags then tags[#out] = c.tags and c.tags[i] or false end
      end
    end
  end
  return out
end

--- The same, but each ring grown by the margin its owner asked for -- what to subtract from ground of your own, as against
--- what to test a seam against. A claim asking for nothing comes back unchanged, which is the flush join.
local function keepOut(out, owner)
  out = out or {}
  for k, c in pairs(claims) do
    if k ~= owner then
      for i = 1, #c.rings do
        out[#out + 1] = (c.margin > 0) and geom.outsetClosedRing2D(c.rings[i], c.margin) or c.rings[i]
      end
    end
  end
  return out
end

--- Everything near `ring` that its owner may not surface: the road rings it is HANDED, grown by `roadMargin`, plus every
--- other tool's claim grown by whatever that tool asked for. `pad` widens the box what counts as near is taken from. `skip`
--- leaves out every ring tagged with it: a site opened for editing is not in the way of itself where a copy of it stands.
local function obstructions(ring, owner, roadRings, roadMargin, pad, skip)
  local out, roads = {}, {}
  if not (ring and #ring >= 3) then return out, roads end
  local px0, py0, px1, py1 = ringBox(ring)
  pad = pad or 0
  px0, py0, px1, py1 = px0 - pad, py0 - pad, px1 + pad, py1 + pad
  local function hits(r, m)
    local x0, y0, x1, y1 = ringBox(r)
    return not (px1 < x0 - m or x1 + m < px0 or py1 < y0 - m or y1 + m < py0)
  end
  -- Boxed before they are grown, with slack for a mitred corner reaching past the margin, so only what is near is outset at
  -- all. The grown ring is then compared as it stands.
  local function grown(r, m)
    if m <= 0 then return hits(r, 0) and r or nil end
    if not hits(r, m * 4) then return nil end
    local g = geom.outsetClosedRing2D(r, m) or r
    return hits(g, 0) and g or nil
  end

  for i = 1, #(roadRings or {}) do
    local g = grown(roadRings[i], roadMargin or 0)
    if g then
      out[#out + 1] = g
      roads[g] = true
    end
  end
  for k, c in pairs(claims) do
    local b = c.box
    if k ~= owner and not (px1 < b[1] - c.margin * 3 or b[3] + c.margin * 3 < px0 or py1 < b[2] - c.margin * 3
                           or b[4] + c.margin * 3 < py0) then
      for i = 1, #c.rings do
        if not (skip and c.tags and c.tags[i] == skip) then
          local g = grown(c.rings[i], c.margin)
          if g then out[#out + 1] = g end
        end
      end
    end
  end
  return out, roads
end

--- Bumped whenever anything is published. For a tool that has to notice somebody else's ground moved under its own, which it
--- cannot be told about directly without the two tools knowing each other.
local function sig() return revision end


-- Public interface.
M.publish = publish
M.clear = clear
M.extents = extents
M.others = others
M.keepOut = keepOut
M.obstructions = obstructions
M.sig = sig

return M