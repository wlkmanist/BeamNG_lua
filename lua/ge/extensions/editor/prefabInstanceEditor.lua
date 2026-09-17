local M = {}
local imgui = ui_imgui

local function prefabInstanceMatchesParent(prefabInstanceId)
  local object = scenetree.findObjectById(prefabInstanceId)

  if not object or (object and object:getClassName() ~= "PrefabInstance") then
    return false
  end

  local matches = object:matchesParentTemplate()
  return matches
end

local function onEditorInitialized()
  log('I','prefabInstance','onEditorInitialized called....')
end

local function onEditorInspectorHeaderGui(inspectorInfo)
  -- log('I','prefabInstance','inspectorInfo = '..dumps(inspectorInfo))
  local showSubSection = true
  local differsFromParent = false
  for i, id in ipairs(inspectorInfo.previousSelectedIds) do
    local object = scenetree.findObjectById(id)
    if not object or (object and object:getClassName() ~= "PrefabInstance") then
      showSubSection = false
    end

    if prefabInstanceMatchesParent(id) == false then
      differsFromParent = true
    end
  end

  if not showSubSection then
    return
  end
  -- log('I','prefabInstance','inspectorInfo = '..dumps(inspectorInfo))

  -- imgui.Begin("PrefabInstanceHeaderMenu", nil, imgui.WindowFlags_NoCollapse + imgui.WindowFlags_AlwaysAutoResize + imgui.WindowFlags_NoResize + imgui.WindowFlags_NoTitleBar)
  -- imgui.End()
  local nodeFlags = imgui.TreeNodeFlags_DefaultOpen
  if imgui.CollapsingHeader1("PrefabInstance", nodeFlags) then
    if differsFromParent then
      if imgui.Button("Make new template") then
      end
      imgui.SameLine();

      local availWidth = imgui.GetContentRegionAvailWidth()
      imgui.PushStyleColor2(imgui.Col_Button, imgui.ImColorByRGB(255,102,0,255).Value)
      -- imgui.PushStyleColor2(imgui.Col_Text, imgui.ImVec4(1,1,1,1))
      if imgui.Button("Apply to parent", imgui.ImVec2(availWidth, 0)) then
      end
      imgui.PopStyleColor()
    end
    imgui.Separator()
  end
end


M.onEditorInspectorHeaderGui = onEditorInspectorHeaderGui
M.onEditorInitialized = onEditorInitialized

return M