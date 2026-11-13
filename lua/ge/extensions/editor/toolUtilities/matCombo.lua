-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Terrain material-layer picker.
local M = {}

-- Module dependencies.
local im = ui_imgui
local util = require('editor/toolUtilities/util')
local style = require('editor/toolUtilities/style')

-- Module constants.
local cols = style.getImguiCols('crystal')
local iconsSmall = im.ImVec2(24, 24)


-- Label for a value: the layer name, or the auto-resolved layer (prefixed "Auto:") when -1.
local function valueLabel(cur, names, autoNames)
  if cur < 0 then
    local ai = util.findMaterialIdx(autoNames or {})
    return ai and ('Auto: ' .. (names[ai] or ('Material ' .. ai))) or 'Auto (none found)'
  end
  return names[cur] or ('Material ' .. cur)
end

-- Draw one picker row. opts: { id, label, default, allowAuto, autoNames, tooltip }.
local function draw(cur, opts)
  -- Coerced rather than trusted: this is a 0-based layer INDEX (-1 being auto), so a caller handing over anything else - a
  -- layer name, or a default that was never a number - would fault in the `< 0` test rather than just read wrong.
  cur = tonumber(cur) or opts.default
  local names = util.getMaterialNames()
  local result = nil

  im.Columns(2, opts.id .. 'C', false)
  im.SetColumnWidth(0, 30)
  if cur ~= opts.default then
    if editor.uiIconImageButton(editor.icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, 'reset_' .. opts.id) then result = opts.default end
    im.tooltip('Reset to default')
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine(); im.NextColumn(); im.PushItemWidth(-1)

  local preview = (opts.label and (opts.label .. ': ') or '') .. valueLabel(cur, names, opts.autoNames)
  if im.BeginCombo('##' .. opts.id, preview) then
    if opts.allowAuto and im.Selectable1(valueLabel(-1, names, opts.autoNames) .. '##auto', cur < 0) and cur >= 0 then
      result = -1
    end
    -- The names are 0-based, matching the paint index, so the last one is at #names rather than #names - 1.
    for i = 0, #names do
      if im.Selectable1((names[i] or ('Material ' .. i)) .. '##' .. i, cur == i) and cur ~= i then result = i end
    end
    im.EndCombo()
  end
  if opts.tooltip then im.tooltip(opts.tooltip) end
  im.PopItemWidth(); im.NextColumn(); im.Columns(1)
  return result
end


-- Public interface.
M.draw = draw

return M