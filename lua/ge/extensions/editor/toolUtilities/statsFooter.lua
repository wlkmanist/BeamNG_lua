-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- The tally footer the kit tools share: "Label N" stats, and the row that moves when you fly away.

local M = {}

-- Module dependencies.
local im = ui_imgui
local triLive = require('editor/toolUtilities/triLive')
local cols = require('editor/toolUtilities/style').getImguiCols('crystal')


--- One "Label N" stat: dull label, tinted number, dull bar in front of it. `lead` starts a fresh row, so no bar.
local function item(label, val, col, lead, tip)
  if not lead then
    im.SameLine(0, 6); im.TextColored(cols.dullWhite, "|"); im.SameLine(0, 6)
  end
  im.TextColored(cols.dullWhite, label); im.SameLine(0, 3); im.TextColored(col, tostring(val or 0))
  if tip then im.tooltip(tip) end
end

--- Drawn tris, range and drawing count for `instances` (triLive entries), with `unique` added in whole as it has no LODs.
--- `fresh` says the list changed since last time, so it may hold a shape never measured.
local function liveRow(instances, unique, fresh)
  if fresh then triLive.note(instances) end
  triLive.scanStep()
  triLive.update(instances)
  local drawn, dist, live, placed, toScan = triLive.get()
  if toScan > 0 then
    item("Drawn tris", "scanning " .. toScan .. " shapes", cols.dullWhite, true,
      'Measuring every LOD of every shape, one shape a frame. Cached to disk after this.')
    return
  end
  item("Drawn tris", drawn + unique, cols.greenB, true,
    'Triangles drawn from where the camera stands: every kit piece in view at its own LOD, less the instance cull, plus the unique geometry. Shadows, decals and street trees are not counted.')
  item("Range", string.format("%.0fm", dist), cols.blueB, nil, 'Camera to the centroid of the placed kit pieces.')
  item("Drawing", live .. "/" .. placed, cols.greenB, nil,
    "Kit pieces being drawn, out of those placed. The rest are off screen or under the instance cull's minimum pixel size.")
end


-- Public interface.
M.item = item
M.liveRow = liveRow

return M