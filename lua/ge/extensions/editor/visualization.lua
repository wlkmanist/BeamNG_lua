-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'editor_aiViz'} -- Having this dependency is not nice, but it's the easiest way to have navgraph vis in here as well as in the ai editor
local logTag = 'editor_visualization'
local im = ui_imgui
local toolWindowName = "visualization"
local lightDebugSettingsWindowName = "visualizationLightDebugSettings"
local materialDebugViz = require('/lua/ge/extensions/util/materialDebugViz')

local var = {}
var.visualizationTypesDefault = {}
var.visibleTypesDefault = {}
var.selectableTypesDefault = {}

local vizFilter = im.ImGuiTextFilter()

local materialDebugVisualizationType = im.IntPtr(0)
local materialDebugVisualizationTypes = nil
local lightDebugVisualizationEnabled = false
local lightDebugData = {}
local lightDebugDataRefreshTime = -1
local lightDebugSettings = {
  sphereRadius = {min = 0.05, max = 5},
  drawDistance = {min = 10, max = 2000}
}
local lightDebugSphereRadius = 0.5
local lightDebugDrawDistance = 120

local lightDebugColors = {
  nightControlled = ColorF(0.15, 0.45, 1, 1),
  enabled = ColorF(0.05, 1, 0.2, 1),
  disabled = ColorF(1, 0.12, 0.08, 1),
  text = ColorF(1, 1, 1, 1),
  textBg = ColorI(0, 0, 0, 190)
}

local lightDebugLegend = {
  {label = "Night controlled", color = lightDebugColors.nightControlled, imColor = im.ImVec4(0.15, 0.45, 1, 1)},
  {label = "Enabled", color = lightDebugColors.enabled, imColor = im.ImVec4(0.05, 1, 0.2, 1)},
  {label = "Disabled", color = lightDebugColors.disabled, imColor = im.ImVec4(1, 0.12, 0.08, 1)}
}

local function truthy(value)
  value = tostring(value or ""):lower()
  return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function getField(obj, fieldName)
  if not obj or not fieldName then return nil end
  if obj.getDynDataFieldbyName then
    local value = obj:getDynDataFieldbyName(fieldName, 0)
    if value ~= nil and tostring(value) ~= "" then return tostring(value) end
  end
  if obj.getField then
    local value = obj:getField(fieldName, 0)
    if value ~= nil and tostring(value) ~= "" then return tostring(value) end
  end
end

local function isLightObject(obj)
  if not obj then return false end
  if obj.isSubClassOf then
    local ok, result = pcall(obj.isSubClassOf, obj, "LightBase")
    if ok and result then return true end
  end
  local className = obj.getClassName and obj:getClassName() or obj.className or ""
  return className == "PointLight" or className == "SpotLight" or className == "LightBase"
end

local function getLightPosition(obj)
  if obj and obj.getPosition then
    local ok, pos = pcall(obj.getPosition, obj)
    if ok and pos then return pos end
  end
  if obj and obj.getWorldBox then
    local ok, box = pcall(obj.getWorldBox, obj)
    if ok and box and box.getCenter then return box:getCenter() end
  end
end

local function refreshLightDebugData()
  local now = os.clock()
  if now - lightDebugDataRefreshTime < 0.75 then return end
  lightDebugDataRefreshTime = now

  local names = {}
  if scenetree.findSubClassObjects then
    names = scenetree.findSubClassObjects("LightBase") or {}
  else
    local seen = {}
    for _, className in ipairs({"LightBase", "PointLight", "SpotLight"}) do
      for _, name in ipairs(scenetree.findClassObjects(className) or {}) do
        if not seen[name] then
          seen[name] = true
          names[#names + 1] = name
        end
      end
    end
  end

  table.clear(lightDebugData)
  for _, name in ipairs(names) do
    local obj = scenetree.findObject(name)
    if obj and isLightObject(obj) then
      local pos = getLightPosition(obj)
      if pos then
        local nightControlled = truthy(getField(obj, "nightLight"))
        local enabledValue = getField(obj, "isEnabled")
        local enabled = enabledValue == nil or truthy(enabledValue)
        local color = nightControlled and lightDebugLegend[1].color or (enabled and lightDebugLegend[2].color or lightDebugLegend[3].color)
        local className = obj.getClassName and obj:getClassName() or obj.className or "Light"
        local radius = tonumber(getField(obj, className == "SpotLight" and "range" or "radius")) or 0

        lightDebugData[#lightDebugData + 1] = {
          pos = vec3(pos),
          color = color,
          label = string.format(
            "%s\n%s%s%s",
            obj.getName and obj:getName() or tostring(name),
            enabled and "enabled" or "disabled",
            nightControlled and " | night controlled" or "",
            radius > 0 and string.format(" | %.1fm", radius) or ""
          )
        }
      end
    end
  end
end

local function drawLightDebugVisualization()
  if not lightDebugVisualizationEnabled or not debugDrawer or not scenetree then return end
  refreshLightDebugData()

  local camPos = core_camera and core_camera.getPosition and core_camera.getPosition()
  if not camPos then return end

  local drawDistanceSq = lightDebugDrawDistance * lightDebugDrawDistance
  local textDistanceSq = math.min(lightDebugDrawDistance, 25) ^ 2
  local textCount = 0

  for _, data in ipairs(lightDebugData) do
    local distSq = (data.pos - camPos):squaredLength()
    if distSq <= drawDistanceSq then
      debugDrawer:drawSphere(data.pos, lightDebugSphereRadius, data.color)

      if distSq <= textDistanceSq and textCount < 12 then
        textCount = textCount + 1
        debugDrawer:drawTextAdvanced(data.pos, String(data.label), lightDebugColors.text, true, false, lightDebugColors.textBg)
      end
    end
  end
end

local function drawLightDebugSettingsWindow()
  if not lightDebugVisualizationEnabled then return end

  if editor.beginWindow(lightDebugSettingsWindowName, "Light Visualization", im.WindowFlags_AlwaysAutoResize, true) then
    local sphereRadius = im.FloatPtr(lightDebugSphereRadius)
    im.Text("Sphere size")
    im.SameLine()
    im.SetNextItemWidth(180)
    if im.SliderFloat("##lightDebugSphereRadius", sphereRadius, lightDebugSettings.sphereRadius.min, lightDebugSettings.sphereRadius.max, "%.2fm") then
      lightDebugSphereRadius = sphereRadius[0]
    end

    local drawDistance = im.FloatPtr(lightDebugDrawDistance)
    im.Text("Draw distance")
    im.SameLine()
    im.SetNextItemWidth(180)
    if im.SliderFloat("##lightDebugDrawDistance", drawDistance, lightDebugSettings.drawDistance.min, lightDebugSettings.drawDistance.max, "%.0fm") then
      lightDebugDrawDistance = drawDistance[0]
    end

    im.Separator()
    im.Text("Legend")
    for _, item in ipairs(lightDebugLegend) do
      im.ColorButton("##lightDebugLegend" .. item.label, item.imColor, 0, im.ImVec2(16, 16))
      im.SameLine()
      im.Text(item.label)
    end
  end
  editor.endWindow()
end

local function updateVisSettings()
  local tbl = {}
  for _, type in ipairs(editor.getVisualizationTypes()) do
    local active = editor.getVisualizationType(type.name)
    tbl[type.name] = active
  end
  editor.setPreference("gizmos.visualization.visTypes", tbl)
end

local function drawResetButton(itemPath)
  im.Spacing(im.ImVec2(0, 0))
  local prefWindowCurrWidth = im.GetContentRegionAvailWidth();
  im.SameLine(prefWindowCurrWidth - 133 * im.uiscale[0])
  if im.Button("Reset To Defaults") then
    im.OpenPopup("Reset To Defaults")
  end
  if im.IsItemHovered() then im.SetTooltip("Reset all preferences in this tab to their default values") end
  -- Reset confirmation
  if im.BeginPopupModal("Reset To Defaults", nil, im.WindowFlags_AlwaysAutoResize) then
    im.Text("Do you really want to reset all preferences in this tab to default values ?\n"..
               "Warning: This operation is not undoable.\n\n\n")
               im.Separator()
    if im.Button("Yes", im.ImVec2(120,0)) then
      im.CloseCurrentPopup()
      local item = editor.preferencesRegistry:findItem(itemPath)
      if itemPath == "gizmos.visualization.visTypes" then
        editor.setPreference(itemPath, deepcopy(var.visualizationTypesDefault))
      elseif itemPath == "gizmos.visualization.visible" then
        editor.setPreference(itemPath, deepcopy(var.visibleTypesDefault))
      elseif itemPath == "gizmos.visualization.selectable" then
        editor.setPreference(itemPath, deepcopy(var.selectableTypesDefault))
      end
    end
    im.SameLine()
    if im.Button("No", im.ImVec2(120,0)) then im.CloseCurrentPopup() end
    im.EndPopup()
  end
end

local function onEditorGui()
  drawLightDebugVisualization()

  if editor.beginWindow(toolWindowName, "Visualization") then
    --  Viz type filter search box
    im.Text("Filter Types:")
    im.SameLine()
    im.PushID1("VizSearchFilter")
    if editor.uiInputSearchTextFilter("##vizSearchFilter", vizFilter, im.GetContentRegionAvailWidth(), nil) then
      if ffi.string(im.TextFilter_GetInputBuf(vizFilter)) == "" then
        im.ImGuiTextFilter_Clear(vizFilter)
      end
    end
    im.PopID()
    if im.IsItemHovered() then im.SetTooltip("Filter Types") end
    -- Filter validator
    local filterQuery = string.gsub(ffi.string(im.TextFilter_GetInputBuf(vizFilter)), "[^%w_]+", " ")   -- sanitize
    filterQuery = string.gsub(filterQuery, "^%s*(.-)%s*$", "%1")  -- trim edges
    local filterTokens = {}
    for token in string.gmatch(filterQuery, "[%w_]+") do  -- split
      table.insert(filterTokens, string.lower(token))     -- lower case
    end
    local displayType = function(type, debug)
      if #filterTokens == 0 then return true end  -- #NoFilter :3
      for _, token in ipairs(filterTokens) do
        --  lower case matching
        if debug and (string.match(string.lower(type.name), token)
            or string.match(string.lower(type.displayName), token)) then
          return true
        elseif not debug and string.match(string.lower(type), token) then
          return true
        end
      end
      return false
    end
    --  Tabs
    local tabNo = 1
    if im.BeginTabBar("decal editor##") then
      if im.BeginTabItem("Debug") then
        tabNo = 1
        im.EndTabItem()
      end
      if im.BeginTabItem("Visible") then
        tabNo = 2
        im.EndTabItem()
      end
      if im.BeginTabItem("Selectable") then
        tabNo = 3
        im.EndTabItem()
      end
      im.EndTabBar()
    end

    im.BeginChild1("visTypes")
    local nItems = 0    -- Items count
    if tabNo == 1 then
      drawResetButton("gizmos.visualization.visTypes")

      if displayType({name = "MaterialDebug", displayName = "Material Debug"}, true) then
        local materialDebugVisualizationTypeNames = {}
        for _,v in ipairs(materialDebugVisualizationTypes) do
          table.insert(materialDebugVisualizationTypeNames, v.displayName)
        end

        if im.Combo1("Material Debug", materialDebugVisualizationType, im.ArrayCharPtrByTbl(materialDebugVisualizationTypeNames)) then
          materialDebugVisualizationTypes[(materialDebugVisualizationType[0] + 1)].setter()
        end
        if materialDebugVisualizationTypes[(materialDebugVisualizationType[0] + 1)].info then
          materialDebugVisualizationTypes[(materialDebugVisualizationType[0] + 1)].info()
          im.Separator()
        end
      end

      local tbl = {}
      for _, type in ipairs(editor.getVisualizationTypes()) do
        local active = im.BoolPtr(editor.getVisualizationType(type.name))
        if displayType(type, true) then
          nItems = nItems + 1
          if im.Checkbox(type.displayName, active) then
            editor.setVisualizationType(type.name, active[0])
            updateVisSettings()
          end
        end
      end
    end
    if tabNo == 2 then
      drawResetButton("gizmos.visualization.visible")
      local classes = worldEditorCppApi.getRenderableObjectClassNames()
      for _, name in ipairs(classes) do
        local visible = im.BoolPtr(editor.getObjectTypeVisible(name))
        if displayType(name) then
          nItems = nItems + 1
          if im.Checkbox(name, visible) then
            editor.setObjectTypeVisible(name, visible[0])
            editor.getPreference("gizmos.visualization.visible")[name] = visible[0]
            if editor.getPreference("gizmos.visualization.saveVisualizationSettings") then
              editor.savePreferences()
            end
          end
        end
      end
    end
    if tabNo == 3 then
      drawResetButton("gizmos.visualization.selectable")
      local classes = worldEditorCppApi.getRenderableObjectClassNames()
      for _, name in ipairs(classes) do
        local selectable = im.BoolPtr(editor.getObjectTypeSelectable(name))
        if displayType(name) then
          nItems = nItems + 1
          if im.Checkbox(name, selectable) then
            editor.setObjectTypeSelectable(name, selectable[0])
            editor.getPreference("gizmos.visualization.selectable")[name] = selectable[0]
            if editor.getPreference("gizmos.visualization.saveVisualizationSettings") then
              editor.savePreferences()
            end
          end
        end
      end
    end
    if nItems == 0 then
      im.Text("No match")
    end
    im.EndChild()
  end
  editor.endWindow()
  drawLightDebugSettingsWindow()
  materialDebugViz.drawLegendWindow()
end

local function onEditorPreferenceValueChanged(path, value)
  if path == "gizmos.visualization.visTypes" then
    for _, type in ipairs(editor.getVisualizationTypes()) do
      if value[type.name] ~= nil then
        editor.setVisualizationType(type.name, value[type.name])
      else
        -- just set this viz to false, clearing it
        editor.setVisualizationType(type.name, false)
      end
    end
  end

  if path == "gizmos.visualization.visible" then
    for _, name in ipairs(worldEditorCppApi.getObjectClassNames()) do
      if value[name] ~= nil then
        editor.setObjectTypeVisible(name, value[name])
      end
    end
  end

  if path == "gizmos.visualization.selectable" then
    for _, name in ipairs(worldEditorCppApi.getObjectClassNames()) do
      if value[name] ~= nil then
        editor.setObjectTypeSelectable(name, value[name])
      end
    end
  end

  if path == "gizmos.visualization.saveVisualizationSettings" then
    if value then
      editor.preferencesRegistry:removeNonPersistentItemPath("gizmos.visualization.visTypes")
      editor.preferencesRegistry:removeNonPersistentItemPath("gizmos.visualization.visible")
      editor.preferencesRegistry:removeNonPersistentItemPath("gizmos.visualization.selectable")
    else
      editor.preferencesRegistry:addNonPersistentItemPath("gizmos.visualization.visTypes")
      editor.preferencesRegistry:addNonPersistentItemPath("gizmos.visualization.visible")
      editor.preferencesRegistry:addNonPersistentItemPath("gizmos.visualization.selectable")
    end
  end
end

local function onEditorRegisterPreferences(prefsRegistry)
  local classes = worldEditorCppApi.getObjectClassNames()
  for _, name in ipairs(classes) do
    local visible = im.BoolPtr(editor.getObjectTypeVisible(name))
    local selectable = im.BoolPtr(editor.getObjectTypeSelectable(name))
    var.visibleTypesDefault[name] = visible
    var.selectableTypesDefault[name] = selectable
  end

  prefsRegistry:registerCategory("gizmos")
  prefsRegistry:registerSubCategory("gizmos", "visualization", nil,
  {
    -- {name = {type, default value, desc, label (nil for auto Sentence Case), min, max, hidden, advanced, customUiFunc, enumLabels}}
    -- hidden
    {visTypes = {"table", {}, "", nil, nil, nil, true}},
    {visible = {"table", {}, "", nil, nil, nil, true}},
    {selectable = {"table", {}, "", nil, nil, nil, true}},
    {visualizationDrawDistance = {"int", 250, "Maximum distance to draw debug shapes (only for certain visual and editor modes)", nil, 50, 2000}},
    {saveVisualizationSettings = {"bool", true, "Enable persistent visualization settings"}},
    {showMaterialDebugLegend = {"bool", true, "Show Material Debug legend overlay on screen"}},
  })
end

local function createRenderModeSetter(objName, varName, functionName)
  return function(on)
    VariableRegistry.set(varName, on)
    if _G["toggleLightVisualizer"] then
      _G["toggleLightVisualizer"](objName, on, varName)
    end
  end
end

local function registerNavgraphVisualization(tpe, name)
  editor.registerVisualizationType(
    {type = editor.varTypes.Custom, name = "drawNavGraph"..tpe, displayName = "Navgraph: "..name,
     setter = function(on) editor_aiViz.enableDrawMode(tpe, on)   end,
     getter = function() return editor_aiViz.getDrawMode() == tpe end})
end

local function onEditorInitialized()
  editor.updateVisSettings = updateVisSettings
  editor.registerWindow(toolWindowName, im.ImVec2(500,600))
  editor.registerWindow(lightDebugSettingsWindowName, im.ImVec2(300, 155))
  editor.clearVisualizationTypes()
  editor.registerVisualizationType({type = editor.varTypes.Setting, name = "BeamNGWaypointDrawDebug", displayName = "BeamNG: draw waypoints"})
  registerNavgraphVisualization('type', 'Road Type')
  registerNavgraphVisualization('drivability', 'Road Drivability')
  registerNavgraphVisualization('speedLimit', 'Speed Limit')
  registerNavgraphVisualization('hiddenInNavi', 'Hidden in Navi')
  editor.registerVisualizationType({type = editor.varTypes.Setting, name = "DebugDrawDrawAdvancedText", displayName = "Advanced text drawing"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "GFXDevice.renderWireframe", displayName = "Wireframe Mode"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "SceneManager.renderBoundingBoxes", displayName = "Bounding Boxes"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "SceneManager.lockFrustum", displayName = "Frustum Lock"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "SFXEmitter.renderEmitters", displayName = "Sound Emitters"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "SFXEmitter.renderFarEmitters", displayName = "Far Sound Emitters"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "BeamNGTrigger.drawTriggers", displayName = "Triggers"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "TerrainBlock.debugRender", displayName = "Terrain"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "Engine.Render.DecalMgr.debugRender", displayName = "Decals"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "LightShadowMap.renderFrustums", displayName = "Light Frustums"})
  editor.registerVisualizationType({type = editor.varTypes.Custom, name = "editorLightDebugVisualization", displayName = "Lights Status",
                                    setter = function(on)
                                      lightDebugVisualizationEnabled = on
                                      lightDebugDataRefreshTime = -1
                                      table.clear(lightDebugData)
                                      editor.setWindowVisibility(lightDebugSettingsWindowName, on)
                                    end,
                                    getter = function() return lightDebugVisualizationEnabled end})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "SceneCullingState.disableZoneCulling", displayName = "Disable Zone Culling"})
  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "SceneCullingState.disableTerrainOcclusion", displayName = "Disable Terrain Occlusion"})

  -- TODO These are not used. Can be removed?
  --editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$SFXSpace::isRenderable", displayName = "Render: Sound Spaces"})
  --editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$Zone::isRenderable", displayName = "Zones"})
  --editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$Portal::isRenderable", displayName = "Portals"})
  --editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$OcclusionVolume::isRenderable", displayName = "Occlusion Volumes"})
  --editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$Player::renderCollision", displayName = "Player Collision"})
  --editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$Trigger::renderTriggers", displayName = "Triggers"})
  --editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$PhysicalZone::renderZones", displayName = "PhysicalZones"})

  editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$Nav::Editor::renderMesh", displayName = "NavMesh"})
  editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$Nav::Editor::renderPortals", displayName = "NavMesh portals"})
  editor.registerVisualizationType({type = editor.varTypes.ConVar, name = "$Nav::Editor::renderBVTree", displayName = "NavMesh bounding volume (BV) tree"})

  editor.registerVisualizationType({type = editor.varTypes.LuaVar, name = "ShadowMapPass.disableShadows", displayName = "Disable Shadows", callback = ShadowMapManager.updateShadowDisable})

  editor.registerVisualizationType({type = editor.varTypes.Custom, name = "$AL_LightColorVisualizeVar", displayName = "Advanced Lighting: Light Color Viz",
                                    setter = createRenderModeSetter("AL_LightColorVisualize", "$AL_LightColorVisualizeVar", "toggleLightColorViz"),
                                    getter = function() return VariableRegistry.get("$AL_LightColorVisualizeVar", false) end})

                                    editor.registerVisualizationType({type = editor.varTypes.Custom, name = "$AL_LightSpecularVisualizeVar", displayName = "Advanced Lighting: Light Specular Viz",
                                    setter = createRenderModeSetter("AL_LightSpecularVisualize", "$AL_LightSpecularVisualizeVar", "toggleLightSpecularViz"),
                                    getter = function() return VariableRegistry.get("$AL_LightSpecularVisualizeVar", false) end})

                                    editor.registerVisualizationType({type = editor.varTypes.Custom, name = "$AL_NormalsVisualizeVar", displayName = "Advanced Lighting: Normals Viz",
                                    setter = createRenderModeSetter("AL_NormalsVisualize", "$AL_NormalsVisualizeVar", "toggleNormalsViz"),
                                    getter = function() return VariableRegistry.get("$AL_NormalsVisualizeVar", false) end})

                                    editor.registerVisualizationType({type = editor.varTypes.Custom, name = "$AL_DepthVisualizeVar", displayName = "Advanced Lighting: Depth Viz",
                                    setter = createRenderModeSetter("AL_DepthVisualize", "$AL_DepthVisualizeVar", "toggleDepthViz"),
                                    getter = function() return VariableRegistry.get("$AL_DepthVisualizeVar", false) end})

                                    editor.registerVisualizationType({type = editor.varTypes.Custom, name = "$AL_VelocityVisualizeVar", displayName = "Advanced Lighting: Velocity Buffer Viz",
                                    setter = createRenderModeSetter("AL_VelocityVisualize", "$AL_VelocityVisualizeVar", "toggleVelocityViz"),
                                    getter = function() return VariableRegistry.get("$AL_VelocityVisualizeVar", false) end})

                                    if ResearchVerifier.isTechLicenseVerified() then
    editor.registerVisualizationType({type = editor.varTypes.Custom, name = "$AnnotationVisualizeVar", displayName = "Annotation Viz",
                                      setter = createRenderModeSetter("AnnotationVisualize", "$AnnotationVisualizeVar", "toggleAnnotationVisualize"),
                                      getter = function() return VariableRegistry.get("$AnnotationVisualizeVar", false) end})
  end

  -- Material Debug Visualization
  materialDebugViz.onExtensionLoaded()
  materialDebugVisualizationTypes = materialDebugViz.getTypes()
  materialDebugVisualizationType = materialDebugViz.getIndexPtr()

  if not editor.getPreference("gizmos.visualization.saveVisualizationSettings") then
    editor.preferencesRegistry:addNonPersistentItemPath("gizmos.visualization.visTypes")
    editor.preferencesRegistry:addNonPersistentItemPath("gizmos.visualization.visible")
    editor.preferencesRegistry:addNonPersistentItemPath("gizmos.visualization.selectable")
  end

  -- Fill visualizationTypesDefault here as VisualizationTypes are not available in onEditorRegisterPreferences
  for _, type in ipairs(editor.getVisualizationTypes()) do
    if type.name == "SFXEmitter.renderEmitters" or
       type.name == "BeamNGWaypointDrawDebug" or
       type.name == "SceneCullingState.disableTerrainOcclusion" then
      var.visualizationTypesDefault[type.name] = true
    else
      var.visualizationTypesDefault[type.name] = false
    end
  end
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onEditorRegisterPreferences = onEditorRegisterPreferences
M.onEditorPreferenceValueChanged = onEditorPreferenceValueChanged

return M