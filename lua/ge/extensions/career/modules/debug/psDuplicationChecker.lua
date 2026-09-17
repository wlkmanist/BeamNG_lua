-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.debugOrder = 11
M.debugName = "Parking Spot Duplication Checker"


local im = ui_imgui

local filePathA = "/levels/west_coast_usa/city.sites.json"
local filePathB = "/levels/west_coast_usa/facilities/delivery/mixed.sites.json"


M.drawDebugFunctions = function()



end


local results = {}

M.compareFiles = function()
  results = {}

  local sitesA = gameplay_sites_sitesManager.loadSites(filePathA, true, true)
  local sitesB = gameplay_sites_sitesManager.loadSites(filePathB, true, true)
  for _, psA in ipairs(sitesA.parkingSpots.sorted) do
    for _, psB in ipairs(sitesB.parkingSpots.sorted) do
      local rotA, rotB = psA.rot, psB.rot
      local xA, yA, zA = rotA * vec3(psA.scl.x / 2, 0, 0), rotA * vec3(0, psA.scl.y / 2, 0), rotA * vec3(0, 0, psA.scl.z / 2)
      local xB, yB, zB = rotB * vec3(psB.scl.x / 2, 0, 0), rotB * vec3(0, psB.scl.y / 2, 0), rotB * vec3(0, 0, psB.scl.z / 2)

      if overlapsOBB_OBB(psA.pos, xA, yA, zA, psB.pos, xB, yB, zB ) then
        table.insert(results,{
          a = psA,
          b = psB
        })
      end
    end
  end
end


local function drawDebugMenu()
  if im.Begin("PS Duplication Checker") then
    if im.Button("File A Picker") then
      extensions.editor_fileDialog.openFile(
        function(data)
          filePathA = data.filepath
          print(filePathA)
        end, {{"Sites", ".sites.json"}})
    end
    if im.Button("File B Picker") then
      extensions.editor_fileDialog.openFile(
        function(data)
          filePathB = data.filepath
          print(filePathB)
        end, {{"Sites", ".sites.json"}})
    end
    im.Text("File A: " .. dumps(filePathA))
    im.Text("File B: " .. dumps(filePathB))
    if im.Button("Compare") then
      M.compareFiles()
    end
    im.Separator()
    for _, r in ipairs(results) do
      im.Selectable1(string.format("%s & %s", r.a.name or "?", r.b.name or "?"))
      r.a:drawDebug(nil,{ 1, 0.5, 0, 0.5 })
      simpleDebugText3d(r.a.name, r.a.pos)
      r.b:drawDebug(nil, { 0, 0.5, 1, 0.5 })
      simpleDebugText3d(r.b.name, r.b.pos)
    end
  end
  im.End()
end
M.drawDebugMenu = drawDebugMenu

-- extensions.load("career/modules/debug/psDuplicationChecker") career_modules_debug_psDuplicationChecker.show()
M.show = function()
  M.onUpdate = M.drawDebugMenu
  extensions.hookUpdate("onUpdate")
end
return M
