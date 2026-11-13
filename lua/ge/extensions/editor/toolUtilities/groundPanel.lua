-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The shared terraform's settings (groundPass), drawn the same in every tool's Terrain tab.

local M = {}

-- Module dependencies.
local groundPass = require('editor/toolUtilities/groundPass')
local widgets = require('editor/roadNetwork/ui/widgets')

-- Module constants.
local im = ui_imgui
local cols = widgets.cols
local params, defaults = groundPass.params, groundPass.defaults
local LABEL_W = 90 -- where a row's ticks start after its label


local function knob(field, lo, hi, fmt, tip, isInt)
  local row = isInt and widgets.resetSliderRowI or widgets.resetSliderRowF
  local v, ch, rc = row('groundPass_' .. field, '##groundPass_' .. field, params[field], lo, hi, fmt, defaults[field], tip,
    string.format('Reset to default (%g)', defaults[field]))
  if rc then params[field] = defaults[field] elseif ch then params[field] = v end
end

-- A row's label, its ticks to follow on the same line.
local function rowLabel(text, tip)
  im.TextColored(cols.greenB, text)
  im.tooltip(tip)
  im.SameLine(LABEL_W)
end

local function tick(field, label, tip)
  local p = im.BoolPtr(params[field] ~= false)
  if im.Checkbox(label .. '###groundPass_' .. field, p) then params[field] = p[0] end
  im.tooltip(tip)
end

-- Which networks a Build covers, in every tool: the bridges and tunnels it flags on them and the ground it shapes to them.
local function drawNetworks()
  rowLabel('Networks:', 'What Build covers.')
  tick('roads', 'Roads', 'Include the roads.')
  im.SameLine()
  tick('rail', 'Rail', 'Include the rail.')
end

-- The Terraform tick and, when it is on, the blend and abutment settings.
local function draw()
  rowLabel('Terrain:', 'Ground shaping for the ticked networks.')
  tick('on', 'Terraform', 'Shape the ground to the networks. Off restores it.')
  if not params.on then return end
  knob('doi', 5.0, 100.0, 'Blend distance (m) = %.1f', 'Blend distance back to natural ground.')
  knob('margin', 0.0, 20.0, 'Margin (m) = %.2f', 'Flat ground beside the road or track.')
  knob('falloff', 1.0, 8.0, 'Falloff = %.1f', 'Blend steepness.')
  knob('smooth', 0, 15, 'Smoothing steps = %d', 'Blend smoothing passes.', true)
  knob('roughness', 0.0, 1.0, 'Roughness = %.2f', 'Noise height in the blend.')
  knob('scale', 0.0, 1.0, 'Scale = %.2f', 'Noise size: low is large bumps.')
  im.TextColored(cols.dullWhite, 'Bridge abutments:')
  knob('abutLen', 0.0, 40.0, 'Length (m) = %.1f', 'Ground raised to the deck under each bridge end.')
  knob('abutShoulder', 0.0, 5.0, 'Shoulder (m) = %.2f', 'Flat ground beside the bridge ends.')
end


-- Public interface.
M.rowLabel = rowLabel
M.drawNetworks = drawNetworks
M.draw = draw

return M