-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Window->Tech->Road Network Import/Exporter, visible with .tech license

local M = {}

local im = ui_imgui

local toolWindowName = 'RoadNetworkImportExporter'
local exportedFilename = nil
local osmExportedFilename = nil
local sumoExportedFilename = nil
local sumo_filename = nil
local importResult = nil
local importLabel = nil
local enabled = nil
local terrain = nil

-- Import options, mirroring the Road Architect 'Import Options' sub-window.
local importPlaceMode = im.IntPtr(0)                                                                -- 0 = as in file, 1 = custom (X, Y), 2 = camera XY.
local importPlaceX = im.FloatPtr(0.0)
local importPlaceY = im.FloatPtr(0.0)
local importO2T = im.BoolPtr(false)                                                                 -- Offset the import vertically, to sit on the existing terrain.
local importCO = im.BoolPtr(false)                                                                  -- Offset the import vertically, by a custom amount.
local importCustomOffset = im.FloatPtr(0.0)
local importTT2I = im.BoolPtr(false)                                                                -- Terraform the terrain to fit the import.
local domainOfInfluence = im.IntPtr(30)
local terraMargin = im.FloatPtr(1.0)

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  if enabled == nil then enabled = ResearchVerifier.isTechLicenseVerified() end
  if not enabled then return end
  editor.registerWindow(toolWindowName, im.ImVec2(600,600))
  editor.addWindowMenuItem('Road Network Import/Exporter', onWindowMenuItem, {groupMenuName = 'Tech'})
end

local function onEditorActivated()
  if not enabled then return end
  terrain = extensions.editor_terrainEditor.getTerrainBlock()
end

local function buildImportOptions()
  return {
    placeMode = importPlaceMode[0],
    placeX = importPlaceX[0],
    placeY = importPlaceY[0],
    offsetToTerrain = importO2T[0],
    verticalOffset = importCO[0] and importCustomOffset[0] or nil,
    terraform = importTT2I[0],
    domainOfInfluence = domainOfInfluence[0],
    margin = terraMargin[0] }
end

local function runImport(label, moduleName, filePath)
  importLabel = label
  local options = buildImportOptions()
  local ok, result = pcall(function()
    return require(moduleName).importFromFile(filePath, options)
  end)
  if ok then
    importResult = result
  else
    importResult = {success = false, error = tostring(result)}
  end
end

local function drawImportResult()
  if not importResult then return end
  if importResult.success then
    im.Text(string.format("%s: imported %d road(s), skipped %d.",
      importLabel, importResult.importedRoadCount or 0, importResult.skippedRoadCount or 0))
    if (importResult.warningCount or 0) > 0 then
      im.Text(string.format("Warnings: %d", importResult.warningCount))
      for _, warning in ipairs(importResult.warnings or {}) do
        im.TextWrapped("  " .. warning)
      end
    end
  else
    im.TextWrapped(importLabel .. " import failed: " .. tostring(importResult.error or "Unknown error"))
  end
end

local function openImportDialog(label, moduleName, filters)
  extensions.editor_fileDialog.openFile(
    function(data)
      runImport(label, moduleName, data.filepath)
    end,
    filters,
    false,
    "/")
end

local function exportOpenDrive()
  exportedFilename = nil
  extensions.editor_fileDialog.saveFile(
    function(data)
      local filename = data.filepath
      extensions.tech_openDriveExporter.export(filename:sub(1, -(#".xodr" + 1)))
      exportedFilename = FS:virtual2Native(filename)
    end,
    {{"OpenDrive",".xodr"}},
    false,
    "/",
    "File already exists.\nDo you want to overwrite the file?")
end

local function exportOpenStreetMap()
  osmExportedFilename = nil
  extensions.editor_fileDialog.saveFile(
    function(data)
      local filename = data.filepath
      extensions.tech_openStreetMapExporter.export(filename:sub(1, -(#".osm" + 1)))
      osmExportedFilename = FS:virtual2Native(filename)
    end,
    {{"OpenStreetMap",".osm"}},
    false,
    "/",
    "File already exists.\nDo you want to overwrite the file?")
end

local function exportSumo()
  sumoExportedFilename = nil
  extensions.editor_fileDialog.saveFile(
    function(data)
      local filename = data.filepath
      sumo_filename = filename
      extensions.tech_sumoExporter.export(sumo_filename:sub(1, -(#".xml" + 1)))
      sumoExportedFilename = FS:virtual2Native(sumo_filename)
    end,
    {{"SUMO",".xml"}},
    false,
    "/",
    "File already exists.\nDo you want to overwrite the file?")
end

-- Draws the shared import options. These are applied to whichever format is imported.
local function drawImportOptions()
  if not im.CollapsingHeader1("Import Options", im.TreeNodeFlags_DefaultOpen) then return end

  im.Text("Placement (XY)")
  if im.RadioButton2("As in file###importPlaceFile", importPlaceMode, 0) then
    importPlaceMode[0] = 0
  end
  im.tooltip('Keep the horizontal position from the imported file.')
  if im.RadioButton2("Custom (X, Y)###importPlaceCustom", importPlaceMode, 1) then
    importPlaceMode[0] = 1
  end
  im.tooltip('Move the network so the first road start node is at the given world X and Y.')
  if im.RadioButton2("Camera position###importPlaceCamera", importPlaceMode, 2) then
    importPlaceMode[0] = 2
  end
  im.tooltip('Move the network so the first road start node is at the current free-camera XY when you import.')

  local placeFieldW = 140 * im.uiscale[0]

  if importPlaceMode[0] == 1 then
    im.PushItemWidth(placeFieldW)
    im.InputFloat("X###importPlaceX", importPlaceX, 1.0, 10.0)
    im.InputFloat("Y###importPlaceY", importPlaceY, 1.0, 10.0)
    im.PopItemWidth()
    if im.Button("Use camera XY###importPlaceFromCam") then
      local camPos = core_camera.getPosition()
      importPlaceX[0], importPlaceY[0] = camPos.x, camPos.y
    end
    im.tooltip('Copy the current editor camera X and Y into the fields above.')
  elseif importPlaceMode[0] == 2 then
    local camPos = core_camera.getPosition()
    im.Text(string.format("Camera: %.1f, %.1f", camPos.x, camPos.y))
  end

  im.Separator()
  im.Text("Offset (Z)")

  if im.Checkbox("Offset To Terrain", importO2T) then
    if importO2T[0] then
      importCO[0] = false
    end
  end
  im.tooltip('Apply a vertical offset to the imported road network, so it sits on the existing terrain.')

  if im.Checkbox("Use Custom Offset", importCO) then
    if importCO[0] then
      importO2T[0] = false
    end
  end
  im.tooltip('Apply a custom vertical offset to the imported road network.')

  if importCO[0] then
    im.PushItemWidth(placeFieldW)
    im.InputFloat("Offset", importCustomOffset, 0.1, 0.0)
    im.tooltip('Sets the custom vertical offset amount.')
    im.PopItemWidth()
  end

  if terrain then
    im.Checkbox("Terraform Terrain To Import", importTT2I)
    im.tooltip('Terraform the terrain to fit the imported road network.')
  end

  if importTT2I[0] then
    im.PushItemWidth(placeFieldW)
    im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
    im.SliderInt("###rniDOI", domainOfInfluence, 1, 500, "Domain Of Influence (m) %d")
    im.tooltip('Set the domain of influence of the terraforming, in meters.')
    im.SliderFloat("###rniMargin", terraMargin, 0.0, 20.0, "Margin (m) = %.3f")
    im.tooltip('Set the terraforming margin (around road), in meters.')
    im.PopStyleVar()
    im.PopItemWidth()
  end
end

local function drawFormatRow(format, extension, importAction, exportAction, exportStatus)
  im.TableNextRow()

  im.TableNextColumn()
  im.Text(format .. " (" .. extension .. ")")
  im.TextWrapped("Import into the current Road Architect state.")
  if im.Button("Import...##" .. format, im.ImVec2(-1, 0)) then
    importAction()
  end

  im.TableNextColumn()
  im.Text(format .. " (" .. extension .. ")")
  im.TextWrapped("Export the current level road network.")
  if not levelLoaded then
    im.Text("No level currently loaded.")
  elseif im.Button("Export...##" .. format, im.ImVec2(-1, 0)) then
    exportAction()
  end
  if exportStatus then
    exportStatus()
  end
end

local function onEditorGui()
  if not enabled then return end
  if editor.beginWindow(toolWindowName, 'Road Network Import/Exporter', im.WindowFlags_NoCollapse + im.WindowFlags_AlwaysAutoResize) then
    im.TextWrapped("Imports into the current Road Architect state. The World Editor must be initialized.")
    im.TextWrapped("Exports may temporarily pause BeamNG while the road network is processed.")

    drawImportOptions()
    im.Separator()

    local tableFlags = im.TableFlags_BordersInnerV + im.TableFlags_BordersOuter + im.TableFlags_RowBg
    if im.BeginTable("##roadNetworkFormats", 2, tableFlags) then
      im.TableSetupColumn("Import", im.TableColumnFlags_WidthStretch)
      im.TableSetupColumn("Export", im.TableColumnFlags_WidthStretch)
      im.TableHeadersRow()

      drawFormatRow(
        "OpenDRIVE", ".xodr",
        function()
          openImportDialog("OpenDrive", 'editor/roadArchitect/openDriveImport', {{"OpenDrive",".xodr"}})
        end,
        exportOpenDrive,
        function()
          if exportedFilename then
            im.TextWrapped("Exported to '" .. exportedFilename .. "'.")
          end
        end)

      drawFormatRow(
        "OpenStreetMap", ".osm",
        function()
          openImportDialog("OpenStreetMap", 'editor/roadArchitect/osmImport', {{"OpenStreetMap",".osm"}})
        end,
        exportOpenStreetMap,
        function()
          if osmExportedFilename then
            im.TextWrapped("Exported to '" .. osmExportedFilename .. "'.")
          end
        end)

      drawFormatRow(
        "SUMO", ".nod.xml / .edg.xml",
        function()
          openImportDialog(
            "SUMO",
            'editor/roadArchitect/sumoImport',
            {{"SUMO node or edge XML",{".nod.xml",".edg.xml"}}, {"XML",".xml"}})
        end,
        exportSumo,
        function()
          if sumoExportedFilename then
            im.Text("Exported files:")
            im.TextWrapped("  " .. sumo_filename .. ".edg.xml")
            im.TextWrapped("  " .. sumo_filename .. ".nod.xml")
          end
        end)

      im.EndTable()
    end

    drawImportResult()
  end
  editor.endWindow()
end


M.onEditorInitialized = onEditorInitialized
M.onEditorActivated = onEditorActivated
M.onEditorGui = onEditorGui

return M
