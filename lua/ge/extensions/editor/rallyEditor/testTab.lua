-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local logTag = ''

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
C.windowDescription = 'Test'

function C:init(rallyEditor)
  self.path = nil
  self.rallyEditor = rallyEditor

  self.driveline = nil
end

function C:setPath(path)
  self.path = path
end

-- called by RallyEditor when this tab is selected.
function C:selected()
  if not self.path then return end

  -- Note: driveline loading removed as it was not being used
  -- If needed, use DrivelineV3 or Recce to load driveline

  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

-- called by RallyEditor when this tab is unselected.
function C:unselect()
  if not self.path then return end
  -- force redraw of shortcutLegend window
  extensions.hook("onEditorEditModeChanged", nil, nil)
end

function C:draw()
  if not self.path then return end

  if im.Button("Test 1") then
    self:test1()
  end

  if im.Button("Load Recce Mission") then
    local mid = self.path:getMissionId()
    local missionDir = self.path:getMissionDir()
    extensions.unload("gameplay_rally_recceApp")

    extensions.load("gameplay_rally_recceApp")
    gameplay_rally_recceApp.loadMission(mid, missionDir)
    gameplay_rally_recceApp.setDrawDebug(true)
  end

  if im.Button("Unload Recce Mission") then
    extensions.unload("gameplay_rally_recceApp")
  end
end

function C:test1()
  print('-- test1 --------------------------------------------------------')

  local pnName = self.path:getRandomSystemPacenote('precountdown')
  print(tostring(pnName))
end

function C:drawDebugEntrypoint()
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end


