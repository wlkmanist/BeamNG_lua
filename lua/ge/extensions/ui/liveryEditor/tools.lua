local M = {}

local api = extensions.editor_api_dynamicDecals
local uiSelectionApi = extensions.ui_liveryEditor_selection
local uiControlsApi = extensions.ui_liveryEditor_controls

local TOOLS = {
  transform = "transform",
  deform = "deform",
  material = "material",
  mirror = "mirror"
}

local currentTool = nil

M.useTool = function(tool)
  currentTool = tool
  uiControlsApi.useActionMap(tool)
  guihooks.trigger("LiveryEditorToolChanged", currentTool)
end

M.closeCurrentTool = function()
  currentTool = nil
  uiControlsApi.disableAllActionMaps()
  guihooks.trigger("LiveryEditorToolChanged", currentTool)
end

M.getCurrentTool = function()
 return currentTool
end

-- Common Operation function for all tools
M.doOperation = function(funcOperation, ...)
  local selectedLayerUids = uiSelectionApi.getSelectedLayers()

  if #selectedLayerUids < 1 then
    log("W", "", "Attempting to translate with no selected layers")
    return
  end

  for key, layerUid in ipairs(selectedLayerUids) do
    local layer = api.getLayerByUid(layerUid)

    if not layer then
      log("W", "", "Unable to find layer " .. layerUid .. " . Skipping...")
      return
    end

    funcOperation(layer, ...)
  end
end

M.TOOLS = TOOLS

return M
