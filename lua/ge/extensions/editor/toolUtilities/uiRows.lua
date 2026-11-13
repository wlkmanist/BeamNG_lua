-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The row shapes every panel in these tools is built out of: a slider with its reset button in front of it, a label in
-- front of a row of option buttons, and a sub-tab that closes with a line under whatever it drew.
--
-- Shared rather than owned by one tool, because they are what makes the windows read alike. A slider whose reset sits in a
-- 30 px column here and a 40 px column there is two panels to learn instead of one, and that is exactly the drift this is
-- here to stop. The massing editor layers its own undo and tab-jump machinery over these; nothing in here knows about
-- either, which is what lets the placer and the site tools use the same rows without taking that machinery with them.

local M = {}

-- Module dependencies.
local style = require('editor/toolUtilities/style')
local util = require('editor/toolUtilities/util')

-- Module constants.
local im = ui_imgui
local abs, max = math.abs, math.max
local cols = style.getImguiCols('crystal')
local iconsSmall = im.ImVec2(24, 24)
local LABEL_COL_W = 118 -- left label column, so stacked button rows line up under one another

-- Module state.
local sepY = nil -- cursor Y after the last line a list drew, so a tab ending there does not draw a second one on it


--- Reset icon left of the slider (spacer when already at default); caller draws the slider between begin/endSliderRow.
local function beginSliderRow(id, atDefault, onReset)
  im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
  im.Columns(2, id .. 'Cols', false)
  im.SetColumnWidth(0, 30)
  if not atDefault then
    if editor.uiIconImageButton(editor.icons.poi_point_1_round, iconsSmall, cols.blueB, nil, nil, id .. 'Reset') then onReset() end
    im.tooltip("Reset to default")
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine(); im.NextColumn()
  im.PushItemWidth(-1)
end

local function endSliderRow()
  im.PopItemWidth()
  im.NextColumn()
  im.Columns(1)
  im.PopStyleVar()
end

--- Label to the left of a row of buttons.
local function rowLabel(label, tip, col)
  im.AlignTextToFramePadding()
  local x0 = im.GetCursorPosX()
  im.TextColored(col or cols.greenB, label)
  if tip then im.tooltip(tip) end
  -- SameLine at a fixed X pulls the cursor BACKWARDS where the label is wider than the column.
  im.SameLine(max(LABEL_COL_W, x0 + im.CalcTextSize(label).x + im.GetStyle().ItemSpacing.x))
end

--- The icon button throws on a nil glyph, so an unknown name falls back to a plain square.
local function optIcon(name)
  return editor.icons[name] or editor.icons.crop_square
end

--- A row of option buttons any number of which can be lit at once, for a choice that is a mix. `has(id)` says which are lit.
--- Takes the bare { id, tip, icon } rows and the kit's named records alike. `offCol` is the unlit button, as the tool's own
--- option rows draw it. Answers the id clicked, or nil.
local function mixRow(opts, id, has, offCol)
  local hit = nil
  for i = 1, #opts do
    local o = opts[i]
    local oid = o.id or o[1]
    if i > 1 then im.SameLine() end
    local on = has(oid)
    if editor.uiIconImageButton(optIcon(o.icon or o[3]), iconsSmall, on and cols.blueB or offCol, nil, nil,
                                id .. oid) then
      hit = oid
    end
    im.tooltip((o.tip or o[2] or '') .. (on and '\nIn the mix. Click to take it out.' or '\nClick to add it to the mix.'))
  end
  return hit
end

--- A list's closing line, remembered so the sub-tab holding it does not draw a second one straight under it.
local function markSep()
  im.Separator()
  sepY = im.GetCursorPosY()
end

local function beginSubTab(label, flags)
  local ok = util.beginSubTab(label, flags)
  sepY = nil
  return ok
end

--- Every sub-tab closes with a line under its content.
local function endSubTab()
  -- Unless the tab's last word was already a line: a list with nothing picked out of it ends on the one under its box, and
  -- a second one straight under that is the double line every other window in these tools is free of.
  local done = sepY ~= nil and abs(im.GetCursorPosY() - sepY) < 0.5
  if not done and im.GetContentRegionAvail().y > im.GetStyle().ItemSpacing.y then im.Separator() end
  sepY = nil
  util.endSubTab()
end


-- Public interface.
M.LABEL_COL_W = LABEL_COL_W

M.beginSliderRow = beginSliderRow
M.endSliderRow = endSliderRow
M.rowLabel = rowLabel
M.optIcon = optIcon
M.mixRow = mixRow
M.markSep = markSep
M.beginSubTab = beginSubTab
M.endSubTab = endSubTab

return M