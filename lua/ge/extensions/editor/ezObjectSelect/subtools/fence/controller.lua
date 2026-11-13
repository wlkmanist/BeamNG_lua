-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local fenceSession = require("editor/ezObjectSelect/subtools/fence/session")
local selectedFenceAssetPath = nil
local anchorMatchDistance = im.FloatPtr(0.5)
local noOverlap = im.BoolPtr(true)
local statusMessage = nil

local function currentAssetBrowserSelection()
  local assetBrowser = extensions.editor_assetBrowser
  if not assetBrowser or not assetBrowser.getSelectedAsset then return nil end
  return assetBrowser.getSelectedAsset()
end

local function currentEzSelectedMeshPath()
  local selectedIds = editor.selection.object
  local objectId = selectedIds and selectedIds[#selectedIds] or nil
  local obj = objectId and scenetree.findObjectById(objectId) or nil
  local path = obj and obj.getField and obj:getField("shapeName", 0) or nil
  return path and path ~= "" and path or nil
end

function M.drawWorkspace(options)
  options = options or {}
  local modeActive = fenceSession.isActive()
  local asset = currentAssetBrowserSelection()
  local assetIsSelected = asset and asset.selectedInABView
  local canUseAsset = not modeActive
    and assetIsSelected
    and asset.type == "mesh"
    and asset.path ~= nil
  local ezSelectedMeshPath = currentEzSelectedMeshPath()
  local canUseEzSelection = not modeActive and ezSelectedMeshPath ~= nil

  if not canUseAsset then im.BeginDisabled() end
  if im.Button("Use Asset Browser selection##fenceUseSelectedAsset") then
    selectedFenceAssetPath = asset.path
    statusMessage = nil
    extensions.editor_assetBrowser.clearSelectedAsset()
  end
  if not canUseAsset then im.EndDisabled() end

  if not canUseEzSelection then im.BeginDisabled() end
  if im.Button("Use Easy Select object##fenceUseEzSelectedObject") then
    selectedFenceAssetPath = ezSelectedMeshPath
    statusMessage = nil
  end
  if not canUseEzSelection then im.EndDisabled() end

  if not modeActive and not assetIsSelected and not ezSelectedMeshPath then
    im.TextDisabled("Select a mesh in the Asset Browser or with Easy Select")
  elseif not modeActive and assetIsSelected and not canUseAsset and not ezSelectedMeshPath then
    im.TextDisabled("Asset Browser selection is not a mesh")
  end

  im.Separator()
  im.TextUnformatted("Fence asset")
  if selectedFenceAssetPath then
    im.TextWrapped(selectedFenceAssetPath)
  else
    im.TextDisabled("None")
  end

  local canClearAsset = not modeActive and selectedFenceAssetPath ~= nil
  if not canClearAsset then im.BeginDisabled() end
  if im.Button("Clear##fenceClearSelectedAsset") then
    selectedFenceAssetPath = nil
    statusMessage = nil
  end
  if not canClearAsset then im.EndDisabled() end
  if im.Checkbox("No overlap##fenceNoOverlap", noOverlap) and modeActive then
    fenceSession.setNoOverlap(noOverlap[0])
  end
  im.tooltip("Use whole mesh lengths and leave any remainder at the spline end bare")

  im.Separator()
  if modeActive then
    im.TextUnformatted("Fence Mode active")
    im.TextWrapped(fenceSession.isDragging()
      and "Editing fence spline"
      or "Click nodes or the spline to edit; click empty terrain to add nodes")
    im.TextUnformatted(string.format(
      "Selected pieces: %d  Preview pieces: %d",
      fenceSession.getSelectedPieceCount(),
      fenceSession.getPieceCount()))
    im.TextUnformatted(string.format(
      "Spline nodes: %d%s",
      fenceSession.getNodeCount(),
      fenceSession.isLoop() and "  Loop" or ""))
    local commitBlocked = fenceSession.isCapped()
    if commitBlocked then
      im.TextDisabled("Commit disabled: discovery or preview reached the safety limit")
    end
    if commitBlocked then im.BeginDisabled() end
    if im.Button("Exit Fence Mode##exitFenceMode") then
      local count = fenceSession.exitAndCommit()
      statusMessage = count > 0
        and string.format("Created %d fence pieces", count)
        or "No fence created"
    end
    if commitBlocked then im.EndDisabled() end
    im.tooltip("Commit the current preview as ordinary TSStatic objects")
    im.SameLine()
    if im.Button("Cancel Fence##cancelFenceMode") then
      fenceSession.cancel()
      statusMessage = "Fence changes cancelled"
    end
    im.tooltip("Restore the original fence pieces and discard the session")
    local canDeleteFence = fenceSession.getSelectedPieceCount() > 0 and not commitBlocked
    if not canDeleteFence then im.BeginDisabled() end
    if im.Button("Delete Fence##deleteFenceMode") then
      local count = fenceSession.deleteAndCommit()
      statusMessage = string.format("Deleted %d fence pieces", count)
    end
    if not canDeleteFence then im.EndDisabled() end
    im.tooltip("Delete every original object in the selected fence as one undoable action")
  else
    im.SliderFloat(
      "Anchor match distance##fenceAnchorMatchDistance",
      anchorMatchDistance,
      0.05,
      5,
      "%.2f m")
    im.tooltip("Maximum distance between matching short-edge midpoint anchors at the object origin Z")
    local effectiveAssetPath = selectedFenceAssetPath or ezSelectedMeshPath
    local canSelect = effectiveAssetPath ~= nil and options.canEnter ~= false
    if not canSelect then im.BeginDisabled() end
    if im.Button("Select Fence##selectFenceMode") then
      selectedFenceAssetPath = effectiveAssetPath
      local entered, errorMessage = fenceSession.begin({
        assetPaths = {selectedFenceAssetPath},
        anchorDistance = anchorMatchDistance[0],
        noOverlap = noOverlap[0]
      })
      statusMessage = entered and nil or errorMessage
    end
    if not canSelect then im.EndDisabled() end
    im.tooltip("Select the connected fence chosen in Easy Select, or begin a new fence when nothing is selected")
  end

  local sessionMessage = fenceSession.getStatusMessage()
  if sessionMessage then statusMessage = sessionMessage end
  if statusMessage then im.TextWrapped(statusMessage) end
end

function M.update(canAcceptInput)
  return fenceSession.update(canAcceptInput)
end

function M.cancel()
  fenceSession.cancel()
end

function M.isModeActive()
  return fenceSession.isActive()
end

return M
