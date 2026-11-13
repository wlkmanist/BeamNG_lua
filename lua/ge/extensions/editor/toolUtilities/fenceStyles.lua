-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Declarative fence styles: which baked post height/section to use, rail band + count, and default post spacing.

local M = {}

-- Module constants.
local max, ceil = math.max, math.ceil
local styles = {
  postrail = {
    id = 'postrail',
    name = 'Post & Rail',
    postHeight = 1.4,        -- selects the fence_post_sq_*_1_4m shapes
    railCountDefault = 3,
    railCountMin = 1,
    railCountMax = 7,
    railBottom = 0.35,       -- lowest rail centre Z
    railTop = 1.25,          -- highest rail centre Z
    spacingDefault = 2.4,    -- == the longest rail rung, so straight bays are a single rail
  },
  -- A railing round a deck or a terrace: waist height rather than field height, and posts closer together, because it is
  -- there to stop someone going over rather than to mark a boundary.
  deck = {
    id = 'deck',
    name = 'Deck Railing',
    postHeight = 1.0,
    railCountDefault = 3,
    railCountMin = 1,
    railCountMax = 5,
    railBottom = 0.30,
    railTop = 0.90,
    spacingDefault = 1.8,
  },
}
local styleOrder = { 'postrail', 'deck' }


-- Fractional rail positions in [0,1] (0 = bottom, 1 = top) for a layout preset.
local function railFractions(count, layout, out, pitchFrac)
  table.clear(out)
  count = max(1, count or 1)
  if count == 1 then out[1] = 0.5; return out end
  layout = layout or 'pinned'
  pitchFrac = pitchFrac or 0.18
  if layout == 'topGroup' or layout == 'bottomGroup' or layout == 'split' then
    local maxP = 0.9 / max(1, count - 2)
    if pitchFrac > maxP then pitchFrac = maxP end
  end
  if layout == 'even' then
    for i = 1, count do out[i] = i / (count + 1) end
  elseif layout == 'topGroup' then
    out[1] = 0.0 -- lone low rail
    for j = 2, count do out[j] = 1.0 - pitchFrac * (count - j) end -- top rail under the cap, the rest packed a rail-width apart below it
  elseif layout == 'bottomGroup' then
    out[count] = 1.0 -- lone high rail
    for j = 1, count - 1 do out[j] = pitchFrac * (j - 1) end -- bottom rail low, the rest packed a rail-width apart above it
  elseif layout == 'split' then
    local nb = ceil(count / 2)
    local nt = count - nb
    for j = 1, nb do out[j] = pitchFrac * (j - 1) end
    for j = 1, nt do out[nb + j] = 1.0 - pitchFrac * (nt - j) end
  else -- pinned
    for i = 1, count do out[i] = (i - 1) / (count - 1) end
  end
  return out
end

-- Rail centre heights (Z, metres) for a style at a rail count + layout preset.
local function railHeights(style, count, layout, out, railH, postH)
  local b, top = style.railBottom, style.railTop
  if postH and railH and (layout == 'topGroup' or layout == 'bottomGroup' or layout == 'split') then
    local capTop = postH - railH * 0.5 -- highest a rail can sit with its top edge flush under the post cap
    if capTop > top then top = capTop end
  end
  local span = top - b
  local pitchFrac = railH and span > 1e-4 and (railH * 1.25) / span or nil
  railFractions(max(1, count or style.railCountDefault), layout, out, pitchFrac)
  for i = 1, #out do out[i] = b + out[i] * span end
  return out
end

local function get(id)
  return styles[id] or styles.postrail
end


-- Public interface.
M.styles = styles
M.styleOrder = styleOrder

M.railHeights = railHeights
M.railFractions = railFractions
M.get = get

return M