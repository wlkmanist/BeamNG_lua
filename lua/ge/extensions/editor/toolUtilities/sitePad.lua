-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- A flat pad of terrain for a site tool to draw on, and the site's own ground cut into it.

local M = {}

-- Module dependencies.
local ffi = require('ffi')
local util = require('editor/toolUtilities/util')
local terra = require('editor/terraform/terraform')

-- Module constants.
local min, max, huge = math.min, math.max, math.huge
local PAD_SIZE_M = 300.0 -- The square taken flat, in meters. Cut once, at a size nothing the tools can draw will run out of.
local PAD_Z = 50.0 -- The level a site is SET OUT against. Stood well up rather than at zero so a basement, an areaway or a
                   -- flight of steps has ground left under it to be cut out of.
-- What a carve into the pad is blended with, matching what the city builder grades a placed site with: the point of cutting
-- the pad at all is that the tool shows the ground the placer is going to cut, so the two have to agree.
local CARVE_DOI, CARVE_MARGIN, CARVE_FALLOFF, CARVE_SMOOTH = 12.0, 3.0, 2.0, 6

-- Module state. One pad at a time, since only one tool can hold the screen.
local pad = nil
local carved = nil -- the heights the last carve overwrote, so the next one starts from the flat pad again
local carvedFeats = nil -- and what it cut, so a pad put back after a level save is put back cut the same way
local carvedPrio = nil -- and the band it cut them at
local heldFn = nil -- (x0, y0, x1, y1) -> what outranks a site on real ground there; set by whatever grades the level
local beforeEnterFn = nil -- () run before a pad goes down on bare ground, while the real ground can still be changed
local suspended = nil -- where a pad was, while it is off the ground for a level save
local tmpV, tmpLo, tmpHi = vec3(), vec3(), vec3()
local p2i = Point2I(0, 0)


--- The terrain block and the editor that addresses its grid, or nothing when the level has no terrain at all.
local function blocks()
  local tem = extensions.editor_terrainEditor
  if not tem then return nil end
  local tb = tem.getTerrainBlock()
  if not tb then return nil end
  return tb, tem.getTerrainEditor()
end

local function toGrid(te, tb, x, y)
  tmpV:set(x, y, 0)
  te:worldToGridByPoint2I(tmpV, p2i, tb)
  return p2i.x, p2i.y
end

--- The grid measures height from the block's own base, not from the world's zero, and the two are hundreds of meters apart.
--- A level meant in world terms has to be brought into that frame before it is written: taken straight across, a pad meant
--- to stand 50 m up is cut as a pit 460 m deep instead.
local function toGridZ(tb, worldZ)
  return worldZ - tb:getPosition().z
end

--- The ground back as it was. Only heights: whatever the tool built on the pad comes down by its own teardown, and has to,
--- or it would be left standing at the pad's level over ground that is no longer there.
---
--- Anything carved INTO the pad goes with it: the pad remembers the real ground, which is older than any cut made in it.
local function leave()
  if not pad then return false end
  carved, carvedFeats = nil, nil
  local tb = blocks()
  if tb then
    local h, w, x0, y0 = pad.heights, pad.w, pad.gx0, pad.gy0
    for gy = pad.gy0, pad.gy1 do
      local row = (gy - y0) * w
      for gx = pad.gx0, pad.gx1 do
        tb:setHeightGrid(gx, gy, h[row + (gx - x0)])
      end
    end
    tmpLo:set(pad.gx0, pad.gy0, 0); tmpHi:set(pad.gx1, pad.gy1, 0)
    tb:updateGrid(tmpLo, tmpHi)
  end
  pad = nil
  return true
end

--- Take the square centred on (cx, cy) flat, remembering what was there so `leave` can put it back. A pad already down goes
--- back first: two overlapping pads would each remember the other's level as the original ground and lose the real one.
---
--- `drop` takes the ground that far BELOW the set-out level instead of level with it, which is how a tool whose site has
--- ground of its own under it -- a basement, an areaway -- gets to see into it. The site keeps standing at `level()`: the
--- two come apart, and everything that sets something out on the pad wants the set-out level and not the cut surface.
---
--- `real` leaves the ground as it is and only remembers it: a site drawn round its own plot is designed on the ground it
--- will stand on, and the carve and `leave` work the same. Such a pad has no set-out level; `level` is not for it.
local function enter(cx, cy, drop, real)
  local tb, te = blocks()
  if not (tb and te) then return false end
  if beforeEnterFn and not pad then beforeEnterFn() end
  leave()
  local half = PAD_SIZE_M * 0.5
  local x0, y0 = toGrid(te, tb, cx - half, cy - half)
  local x1, y1 = toGrid(te, tb, cx + half, cy + half)
  if x1 < x0 then x0, x1 = x1, x0 end
  if y1 < y0 then y0, y1 = y1, y0 end
  -- Clipped to the block. A site drawn at the very edge of the map gets the part of its pad that exists.
  local gw, gh = terra.gridDims(tb)
  x0, y0, x1, y1 = max(0, x0), max(0, y0), min(gw, x1), min(gh, y1)
  if x1 <= x0 or y1 <= y0 then return false end
  local w, h = x1 - x0 + 1, y1 - y0 + 1
  local heights = ffi.new('double[?]', w * h)
  local padGridZ = toGridZ(tb, PAD_Z - (drop or 0))
  for gy = y0, y1 do
    local row = (gy - y0) * w
    for gx = x0, x1 do
      heights[row + (gx - x0)] = tb:getHeightGrid(gx, gy)
      if not real then tb:setHeightGrid(gx, gy, padGridZ) end
    end
  end
  pad = { gx0 = x0, gy0 = y0, gx1 = x1, gy1 = y1, w = w, h = h, heights = heights, cx = cx, cy = cy,
          drop = drop or 0, real = real or nil }
  if not real then
    tmpLo:set(x0, y0, 0); tmpHi:set(x1, y1, 0)
    tb:updateGrid(tmpLo, tmpHi)
  end
  -- Deliberately NOT setTerrainDirty: the pad is a drawing board that is about to be taken away again, and a level asking to
  -- be saved because a tool was opened would be this module leaving a mark on something that is not its own.
  return true
end

--- Where a tool should centre its pad, given the bounds of what it already holds. The camera's aim when it holds nothing,
--- which is where the tools seed a starter shape, so a fresh site and its pad arrive in the same place.
local function centreFor(ring)
  if ring and #ring > 0 then
    local xMin, yMin, xMax, yMax = huge, huge, -huge, -huge
    for i = 1, #ring do
      local p = ring[i]
      if p.x < xMin then xMin = p.x end
      if p.x > xMax then xMax = p.x end
      if p.y < yMin then yMin = p.y end
      if p.y > yMax then yMax = p.y end
    end
    return (xMin + xMax) * 0.5, (yMin + yMax) * 0.5
  end
  return util.lookAtGround()
end

--- Cut the site's own ground plan into the pad, so a sunk square, a terrace or a flight of steps can be SEEN while it is
--- being drawn instead of only once the site is placed. `features` is the same list the site bakes for the placer, so the
--- ground here and the ground there are cut from one answer.
---
--- The last cut is handed back first: a carve blends into the ground around it, and blending into ground the previous carve
--- already pulled down would eat further into the pad every time. Called with nothing, that hand-back is all it does.
---
--- On real ground `prio` is the site's band, and whatever outranks it nearby goes into the same pass at its own: the cut
--- gives way to a road's verge here exactly as the level's grade will make it.
local function carve(features, prio)
  if not pad then return false end
  if carved then terra.revertBaseline(carved); carved = nil end
  carvedFeats = (features and #features > 0) and features or nil
  carvedPrio = prio
  if not carvedFeats then return true end
  local list = carvedFeats
  if pad.real and prio and heldFn then
    list = {}
    local x0, y0, x1, y1 = huge, huge, -huge, -huge
    for i = 1, #carvedFeats do
      local c = {}
      for k, v in pairs(carvedFeats[i]) do c[k] = v end
      c.priority = c.band and terra.PRIO[c.band] or prio
      list[i] = c
      local pts = c.quad or (c.rings and c.rings[1]) or {}
      for k = 1, #pts do
        x0, y0, x1, y1 = min(x0, pts[k].x), min(y0, pts[k].y), max(x1, pts[k].x), max(y1, pts[k].y)
      end
    end
    local reach = CARVE_DOI + CARVE_MARGIN
    local held = heldFn(x0 - reach, y0 - reach, x1 + reach, y1 + reach)
    for i = 1, #(held or {}) do list[#list + 1] = held[i] end
  end
  -- Nothing else is claiming ground on a drawing board, and a mask left standing from the last cut would hold this one's
  -- cells at the heights that one left them at.
  terra.resetMask()
  local bl = {}
  terra.carvePad(CARVE_DOI, CARVE_MARGIN, CARVE_FALLOFF, list, CARVE_SMOOTH, bl)
  carved = ((bl.n or 0) > 0) and bl or nil
  return true
end

--- The pad off the ground for the duration of a level save, and back down again afterwards. A save writes the terrain as it
--- finds it, so a drawing board left lying there would go into the level as real ground - a 300 m plateau where the map had
--- a hillside, saved because a tool happened to be open at the time.
local function suspend()
  if not pad then return false end
  -- Whatever was cut into it as well as where it was: a pad put back without its cut would leave the tool's sunk square
  -- buried in flat ground, and nothing downstream knows to ask for it again.
  suspended = { cx = pad.cx, cy = pad.cy, feats = carvedFeats, prio = carvedPrio, drop = pad.drop, real = pad.real }
  leave()
  return true
end

local function resume()
  local s = suspended
  suspended = nil
  if not s then return false end
  if not enter(s.cx, s.cy, s.drop, s.real) then return false end
  return carve(s.feats, s.prio)
end

local function isDown() return pad ~= nil end

--- The same, by heightmap cell, in the grid's own units; nil off the pad.
local function cellZ(gx, gy)
  if not pad or gx < pad.gx0 or gx > pad.gx1 or gy < pad.gy0 or gy > pad.gy1 then return nil end
  return pad.heights[(gy - pad.gy0) * pad.w + (gx - pad.gx0)]
end

--- Who answers what outranks a site on real ground: `fn(x0, y0, x1, y1)` returns those features, each carrying its band.
local function setHeld(fn) heldFn = fn end

--- Who gets the real ground once more before a pad remembers it: `fn()` runs as an editor comes in.
local function setBeforeEnter(fn) beforeEnterFn = fn end

--- The ground at (x, y) as it was before the pad went down or anything was cut into it; nil off the pad. What a level is
--- measured from: measured off the cut instead, each cut moves the level the next one is cut to.
local function groundZ(x, y)
  if not pad then return nil end
  local tb, te = blocks()
  if not (tb and te) then return nil end
  local gx, gy = toGrid(te, tb, x, y)
  if gx < pad.gx0 or gx > pad.gx1 or gy < pad.gy0 or gy > pad.gy1 then return nil end
  return pad.heights[(gy - pad.gy0) * pad.w + (gx - pad.gx0)] + tb:getPosition().z
end

--- How far the pad's ground sits below the set-out level, nil with no pad down.
local function drop() return pad and pad.drop end

--- The pad cut again at another drop, where it stands. Its carve is dropped with it: that was cut into the old ground.
local function redrop(d)
  if not pad or pad.drop == d then return false end
  return enter(pad.cx, pad.cy, d, pad.real)
end

--- The world level a site on the pad is SET OUT against. What anything standing on the drawing board should use in place of
--- sampling the ground, which once a site has cut its own shapes into the pad is not flat.
local function level() return PAD_Z end


-- Public interface.
M.enter = enter
M.leave = leave
M.carve = carve
M.suspend = suspend
M.resume = resume
M.isDown = isDown
M.groundZ = groundZ
M.cellZ = cellZ
M.setHeld = setHeld
M.setBeforeEnter = setBeforeEnter
M.drop = drop
M.redrop = redrop
M.level = level
M.centreFor = centreFor

return M