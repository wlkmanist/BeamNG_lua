-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_imgui",
  "ui_imguiUtils",
  "core_camera",
  "core_vehicle_manager",
  "util_screenshotCreator_settings"
}

local im = ui_imgui
local configPath = "/settings/thumbnailNodeOutpaintConfig.json"
local configFile
local tabActive = false
local stroke
local selfChecked = false

local enabled = im.BoolPtr(false)
local brushRadius = im.FloatPtr(24)
local brushColor = im.GetColorU322(im.ImVec4(1, 0.8, 0.1, 0.95))
local brushFill = im.GetColorU322(im.ImVec4(1, 0.8, 0.1, 0.08))
local warningColor = im.ImVec4(1, 1, 0, 1)
local disabledNodesListSize = im.ImVec2(0, 0)

local function normalizeConfigName(configName)
  local normalized = tostring(configName or ""):gsub("\\", "/")
  normalized = normalized:match("([^/]+)$") or normalized
  normalized = normalized:gsub("%.pc$", ""):gsub("%.jpg$", "")
  return normalized ~= "" and normalized or nil
end

local function getVehicleOutpaintKey(vehicle, explicitConfigName)
  if not vehicle then return nil end
  local modelName = vehicle.jbeam or vehicle.JBeam
  local configName = normalizeConfigName(explicitConfigName)
    or normalizeConfigName(vehicle.partConfig)
  if not modelName or not configName then return nil end
  return modelName .. "/" .. configName, modelName, configName
end

local function loadConfig(force)
  if configFile and not force then return configFile end
  configFile = jsonReadFile(configPath)
  if type(configFile) ~= "table" then
    configFile = {}
  end
  if type(configFile.configs) ~= "table" then
    configFile.configs = {}
  end
  return configFile
end

local function saveConfig()
  loadConfig()
  return jsonWriteFile(configPath, configFile, true)
end

local function resolveConfigKey(vehicleOrKey, explicitConfigName)
  if type(vehicleOrKey) == "string" then return vehicleOrKey end
  return getVehicleOutpaintKey(vehicleOrKey, explicitConfigName)
end

local function getDisabledNodes(vehicleOrKey, explicitConfigName, create)
  local configKey = resolveConfigKey(vehicleOrKey, explicitConfigName)
  loadConfig()
  local disabledNodes = configKey and configFile.configs[configKey] or nil
  if not disabledNodes and create and configKey then
    disabledNodes = {}
    configFile.configs[configKey] = disabledNodes
  end
  return disabledNodes or {}
end

local function isMirrorName(value)
  return type(value) == "string" and value:lower():find("mirror", 1, true) ~= nil
end

local function isExternalMirrorEntry(mirror)
  if type(mirror) ~= "table" or not isMirrorName(mirror.mesh) then return false end
  local terminalPath = type(mirror.partPath) == "string"
    and mirror.partPath:match("([^/\\]+)$")
    or nil
  return isMirrorName(mirror.partOrigin)
    or isMirrorName(terminalPath)
end

local function getMirrorOwners(vehicleData)
  local paths = {}
  local origins = {}
  local mirrors = vehicleData and vehicleData.vdata and vehicleData.vdata.mirrors or {}
  for _, mirror in pairs(mirrors) do
    if isExternalMirrorEntry(mirror) then
      if type(mirror.partPath) == "string" then paths[mirror.partPath] = true end
      if type(mirror.partOrigin) == "string" then origins[mirror.partOrigin] = true end
    end
  end
  return paths, origins
end

local function selfCheck()
  assert(isExternalMirrorEntry({
    mesh = "md_series_mirror_R",
    partOrigin = "md_series_mirror_R",
    partPath = "md_series/md_series_mirror_R"
  }))
  assert(not isExternalMirrorEntry({
    mesh = "md_series_intmirror",
    partOrigin = "md_series_cab_regular",
    partPath = "md_series/md_series_cab_regular"
  }))
  return true
end

local function getVehicleNodeData(vehicle)
  local nodes = {}
  if not vehicle then return nodes end
  if not selfChecked then
    selfCheck()
    selfChecked = true
  end

  local vehicleManager = core_vehicle_manager or extensions.core_vehicle_manager
  local vehicleData = vehicleManager and vehicleManager.getVehicleData(vehicle:getId())
  local definitions = vehicleData and vehicleData.vdata and vehicleData.vdata.nodes or {}
  local mirrorPaths, mirrorOrigins = getMirrorOwners(vehicleData)
  local definitionsByCid = {}
  for key, definition in pairs(definitions) do
    if type(definition) == "table" then
      definitionsByCid[definition.cid or key] = definition
    end
  end

  local vehiclePosition = vehicle:getPosition()
  for cid = 0, vehicle:getNodeCount() - 1 do
    local definition = definitionsByCid[cid]
    local nodePosition = vehicle:getNodePosition(cid)
    if nodePosition then
      local nodeName = definition and definition.name
      if not nodeName or nodeName == "" then
        nodeName = "Node " .. tostring(cid)
      end
      nodes[#nodes + 1] = {
        cid = cid,
        key = tostring(cid),
        name = tostring(nodeName),
        ignoreForThumbnailFraming = definition and definition.ignoreForThumbnailFraming == true,
        automaticMirrorOutpaint = definition and (
          mirrorPaths[definition.partPath] == true
          or mirrorOrigins[definition.partOrigin] == true
        ) or false,
        point = nodePosition + vehiclePosition
      }
    end
  end
  return nodes
end

local function getVehicleNode(vehicle, nodeIdentifier)
  local identifier = tostring(nodeIdentifier)
  for _, node in ipairs(getVehicleNodeData(vehicle)) do
    if node.key == identifier or node.name == identifier or node.cid == nodeIdentifier then
      return node
    end
  end
end

local function applySnapshot(configKey, snapshot)
  if not configKey then return false end
  loadConfig()
  if type(snapshot) == "table" and next(snapshot) then
    configFile.configs[configKey] = deepcopy(snapshot)
  else
    configFile.configs[configKey] = nil
  end
  saveConfig()
  return true
end

local function undoChange(actionData)
  stroke = nil
  applySnapshot(actionData.configKey, actionData.old)
end

local function redoChange(actionData)
  stroke = nil
  applySnapshot(actionData.configKey, actionData.new)
end

local function commitChange(actionName, configKey, oldState, newState)
  if editor and editor.history then
    editor.history:commitAction(actionName, {
      configKey = configKey,
      old = deepcopy(oldState),
      new = deepcopy(newState)
    }, undoChange, redoChange, true)
  end
  saveConfig()
end

local function setNodeDisabled(vehicleOrKey, node, disabled, explicitConfigName)
  if not node then return false end
  local configKey = resolveConfigKey(vehicleOrKey, explicitConfigName)
  if not configKey then return false end

  local disabledNodes = getDisabledNodes(configKey, nil, true)
  if disabled then
    if disabledNodes[node.key] ~= node.name then
      disabledNodes[node.key] = node.name
      return true
    end
  elseif disabledNodes[node.key] ~= nil then
    disabledNodes[node.key] = nil
    return true
  end
  return false
end

local function setNodeDisabledWithHistory(vehicleOrKey, node, disabled, explicitConfigName)
  local configKey = resolveConfigKey(vehicleOrKey, explicitConfigName)
  if not configKey or not node then return false end
  local disabledNodes = getDisabledNodes(configKey)
  local oldState = deepcopy(disabledNodes)
  if not setNodeDisabled(configKey, node, disabled) then return false end

  local newState = deepcopy(getDisabledNodes(configKey))
  if not next(newState) then
    configFile.configs[configKey] = nil
  end
  commitChange(
    disabled and "Disable Thumbnail Framing Node" or "Enable Thumbnail Framing Node",
    configKey,
    oldState,
    newState)
  return true
end

local function enableAll(vehicleOrKey, explicitConfigName)
  local configKey = resolveConfigKey(vehicleOrKey, explicitConfigName)
  if not configKey then return false end
  local oldState = deepcopy(getDisabledNodes(configKey))
  if not next(oldState) then return false end
  configFile.configs[configKey] = nil
  commitChange("Enable All Thumbnail Framing Nodes", configKey, oldState, {})
  return true
end

local function finishStroke()
  if not stroke then return end
  if stroke.changed then
    local newState = getDisabledNodes(stroke.configKey)
    if not next(newState) then
      configFile.configs[stroke.configKey] = nil
    end
    commitChange("Paint Thumbnail Framing Nodes", stroke.configKey, stroke.old, newState)
  end
  stroke = nil
end

local function updateBrush(options)
  options = options or {}
  local active = options.active
  if active == nil then active = tabActive end
  active = active and enabled[0] and not options.workerRunning

  local inputAvailable = active
    and editor
    and editor.isViewportHovered()
    and not im.GetIO().WantCaptureMouse
    and not editor.isAxisGizmoHovered()

  if not active then
    finishStroke()
    return
  end

  local vehicle = options.vehicle or getPlayerVehicle(0)
  local configKey = getVehicleOutpaintKey(vehicle, options.configName)
  if not vehicle or not configKey then
    finishStroke()
    return
  end

  local nodes = getVehicleNodeData(vehicle)
  local disabledNodes = getDisabledNodes(configKey)
  local ray = getCameraMouseRay()
  if not ray then
    finishStroke()
    return
  end

  local viewport = im.GetMainViewport()
  local scaledBrushRadius = brushRadius[0] * im.uiscale[0]
  local halfVerticalTan = math.tan(core_camera.getFovRad() * 0.5)
  local viewportHeight = math.max(viewport.Size.y, 1)
  local nodesUnderBrush = {}

  if inputAvailable then
    local drawList = im.GetForegroundDrawList2(viewport)
    local mousePosition = im.GetMousePos()
    im.ImDrawList_AddCircleFilled(drawList, mousePosition, scaledBrushRadius, brushFill, 48)
    im.ImDrawList_AddCircle(drawList, mousePosition, scaledBrushRadius, brushColor, 48, 2 * im.uiscale[0])
  end

  for _, node in ipairs(nodes) do
    local toNode = node.point - ray.pos
    local depth = toNode:dot(ray.dir)
    local worldPerPixel = depth > 0 and 2 * depth * halfVerticalTan / viewportHeight or 0
    local perpendicularSquared = depth > 0
      and math.max(0, toNode:squaredLength() - depth * depth)
      or math.huge
    local worldBrushRadius = worldPerPixel * scaledBrushRadius
    local underBrush = inputAvailable and perpendicularSquared <= worldBrushRadius * worldBrushRadius
    if underBrush then
      nodesUnderBrush[#nodesUnderBrush + 1] = node
    end

    local color
    if underBrush then
      color = ColorF(1, 0.8, 0.1, 1)
    elseif node.ignoreForThumbnailFraming then
      color = ColorF(0.85, 0.2, 1, 0.9)
    elseif disabledNodes[node.key] ~= nil then
      color = ColorF(1, 0.15, 0.1, 0.9)
    else
      color = ColorF(0.2, 0.8, 1, 0.55)
    end
    debugDrawer:drawSphere(node.point, math.max(0.015, worldPerPixel * 4), color)
  end

  local mouseDown = inputAvailable and im.IsMouseDown(0)
  if mouseDown then
    if stroke and stroke.configKey ~= configKey then
      finishStroke()
    end
    if not stroke then
      stroke = {
        configKey = configKey,
        old = deepcopy(disabledNodes),
        changed = false
      }
    end

    local enableNodes = editor.keyModifiers and editor.keyModifiers.ctrl
    for _, node in ipairs(nodesUnderBrush) do
      if setNodeDisabled(configKey, node, not enableNodes) then
        stroke.changed = true
      end
    end
  elseif stroke then
    finishStroke()
  end
end

local function drawTab(options)
  options = options or {}
  tabActive = true

  im.Checkbox("Enable node brush", enabled)
  im.tooltip("Paint vehicle nodes in the 3D viewport while this tab is open.")
  im.SliderFloat("Brush radius", brushRadius, 4, 80, "%.0f px")
  im.TextWrapped("Hold left mouse over the viewport to disable every node inside the brush. Hold Ctrl + left mouse to enable nodes.")
  im.TextDisabled("Cyan: enabled  Red: manually disabled  Purple: ignored by part")

  if options.autoFrame and im.Button("Auto-frame vehicle") then
    options.autoFrame()
  end

  local vehicle = options.vehicle or getPlayerVehicle(0)
  local configKey, modelName, configName = getVehicleOutpaintKey(vehicle, options.configName)
  if not configKey then
    im.TextDisabled("No active vehicle config is available.")
    return
  end

  im.Separator()
  im.TextUnformatted("Config: " .. modelName .. "/" .. configName)

  local disabledNodes = getDisabledNodes(configKey)
  local disabledEntries = {}
  local currentNodes = getVehicleNodeData(vehicle)
  for _, node in ipairs(currentNodes) do
    if disabledNodes[node.key] ~= nil then
      disabledEntries[#disabledEntries + 1] = {key = node.key, name = node.name, node = node}
    end
  end
  table.sort(disabledEntries, function(a, b)
    if a.name == b.name then return a.key < b.key end
    return a.name < b.name
  end)

  im.TextUnformatted("Disabled nodes: " .. tostring(#disabledEntries))
  if #disabledEntries > 0 then
    im.SameLine()
    if im.SmallButton("Enable all") then
      enableAll(configKey)
    end

    disabledNodesListSize.y = 220 * im.uiscale[0]
    if im.BeginChild1("disabledFramingNodes", disabledNodesListSize, true) then
      for _, entry in ipairs(disabledEntries) do
        if im.SmallButton("Enable##nodeOutpaint" .. entry.key) then
          setNodeDisabledWithHistory(configKey, entry.node, false)
        end
        im.SameLine()
        im.TextUnformatted(entry.name .. " [" .. entry.key .. "]")
      end
    end
    im.EndChild()
  else
    im.TextDisabled("No nodes are disabled for this config.")
  end

  if #currentNodes > 0 and #disabledEntries >= #currentNodes then
    im.PushStyleColor2(im.Col_Text, warningColor)
    im.TextWrapped("All nodes are disabled. Procedural framing should use the vehicle OOBB as a safe fallback.")
    im.PopStyleColor()
  end
end

local function beginUiFrame()
  tabActive = false
end

local function setTabActive(value)
  tabActive = value == true
  if not tabActive then finishStroke() end
end

local function drawFramingDebug(framingData, options)
  if not framingData then return end
  options = options or {}

  if options.drawBounds == nil or options.drawOobb == nil or options.drawInputs == nil then
    local settingsExtension = util_screenshotCreator_settings
    local framingContext = settingsExtension and settingsExtension.getFramingContext()
    local debugOptions = framingContext and framingContext.debug or {}
    if options.drawBounds == nil then options.drawBounds = debugOptions.drawBounds end
    if options.drawOobb == nil then options.drawOobb = debugOptions.drawOobb end
    if options.drawInputs == nil then options.drawInputs = debugOptions.drawInputs end
  end

  local edges = {
    {1, 2}, {2, 3}, {3, 4}, {4, 1},
    {5, 6}, {6, 7}, {7, 8}, {8, 5},
    {1, 5}, {2, 6}, {3, 7}, {4, 8}
  }
  if options.drawBounds and framingData.boundsCorners then
    local corners = framingData.boundsCorners
    local lineColor = ColorF(1, 0.5, 0, 0.5)
    for _, edge in ipairs(edges) do
      debugDrawer:drawLineInstance(corners[edge[1]], corners[edge[2]], 2, lineColor, false)
    end
  end

  if options.drawOobb and framingData.bb then
    local corners = {}
    for index = 0, 7 do corners[index + 1] = framingData.bb:getPoint(index) end
    local lineColor = ColorF(0.15, 0.8, 1, 0.85)
    for _, edge in ipairs(edges) do
      debugDrawer:drawLineInstance(corners[edge[1]], corners[edge[2]], 3, lineColor, false)
    end
  end

  if not options.drawInputs then return end
  if not framingData.center or not framingData.camAxisCenter or not framingData.lookAtPoint then return end

  local center = framingData.center
  local cameraAxisCenter = framingData.camAxisCenter
  local axisLength = math.max(1, framingData.halfExtents:length())
  debugDrawer:drawSphere(center, 0.08, ColorF(1, 1, 1, 0.8))
  debugDrawer:drawSphere(cameraAxisCenter, 0.08, ColorF(1, 1, 0, 0.8))
  debugDrawer:drawSphere(framingData.lookAtPoint, 0.08, ColorF(0.1, 1, 0.1, 0.8))

  debugDrawer:drawLineInstance(center, center + framingData.axis0 * axisLength, 1, ColorF(1, 0, 0, 0.5), false)
  debugDrawer:drawLineInstance(center, center + framingData.axis1 * axisLength, 1, ColorF(0, 1, 0, 0.5), false)
  debugDrawer:drawLineInstance(center, center + framingData.axis2 * axisLength, 1, ColorF(0, 0.4, 1, 0.5), false)
  debugDrawer:drawLineInstance(cameraAxisCenter, cameraAxisCenter + framingData.camOffsetAxis * axisLength, 3, ColorF(1, 1, 0, 1), false)

  for _, framingPoint in ipairs(framingData.framingPoints or {}) do
    local color = framingPoint.color or {0.2, 0.8, 1}
    debugDrawer:drawSphere(framingPoint.point, 0.035, ColorF(color[1], color[2], color[3], 0.8))
  end
  for _, mirrorNode in ipairs(framingData.mirrorNodes or {}) do
    debugDrawer:drawSphere(mirrorNode.point, 0.04, ColorF(1, 0.65, 0.1, 0.9))
  end
  for _, disabledNode in ipairs(framingData.disabledNodes or {}) do
    debugDrawer:drawSphere(disabledNode.point, 0.045, ColorF(1, 0.15, 0.1, 0.9))
  end

  debugDrawer:drawTextAdvanced(center + vec3(0, 0, 0.5), String("framing bounds center"), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 192))
  debugDrawer:drawTextAdvanced(cameraAxisCenter, String("camera axis center"), ColorF(1, 1, 0, 1), true, false, ColorI(0, 0, 0, 192))
  debugDrawer:drawTextAdvanced(framingData.lookAtPoint, String("camera target"), ColorF(0.1, 1, 0.1, 1), true, false, ColorI(0, 0, 0, 192))
end

local function drawVehicleNodes(vehicle, explicitConfigName)
  if not vehicle then return end
  local configKey = getVehicleOutpaintKey(vehicle, explicitConfigName)
  local disabledNodes = getDisabledNodes(configKey)
  for _, node in ipairs(getVehicleNodeData(vehicle)) do
    local color
    if node.ignoreForThumbnailFraming then
      color = ColorF(0.85, 0.2, 1, 0.9)
    elseif disabledNodes[node.key] ~= nil then
      color = ColorF(1, 0.15, 0.1, 0.9)
    elseif node.automaticMirrorOutpaint then
      color = ColorF(1, 0.65, 0.1, 0.9)
    else
      color = ColorF(0.2, 0.8, 1, 0.55)
    end
    debugDrawer:drawSphere(node.point, 0.025, color)
  end
end

local function serialize()
  return {
    enabled = enabled[0],
    brushRadius = brushRadius[0]
  }
end

local function deserialize(data)
  if type(data) ~= "table" then return end
  enabled[0] = data.enabled == true or data.nodeOutpaintEnabled == true
  brushRadius[0] = clamp(tonumber(data.brushRadius or data.nodeOutpaintBrushRadius) or 24, 4, 80)
end

local function onExtensionLoaded()
  loadConfig()
end

local function onExtensionUnloaded()
  finishStroke()
end

local function onVehicleSpawned()
  finishStroke()
end

M.getConfigPath = function() return configPath end
M.loadConfig = loadConfig
M.saveConfig = saveConfig
M.getVehicleOutpaintKey = getVehicleOutpaintKey
M.getVehicleNodeData = getVehicleNodeData
M.selfCheck = selfCheck
M.getVehicleNode = getVehicleNode
M.getDisabledNodes = getDisabledNodes
M.getDisabledNodesForKey = function(configKey, create) return getDisabledNodes(configKey, nil, create) end
M.setNodeDisabled = setNodeDisabledWithHistory
M.enableAll = enableAll
M.applySnapshot = applySnapshot
M.undo = undoChange
M.redo = redoChange
M.beginUiFrame = beginUiFrame
M.setTabActive = setTabActive
M.isTabActive = function() return tabActive end
M.drawTab = drawTab
M.updateBrush = updateBrush
M.updateNodeOutpainting = updateBrush
M.finishStroke = finishStroke
M.drawFramingDebug = drawFramingDebug
M.drawVehicleNodes = drawVehicleNodes
M.getControls = function()
  return {
    enabled = enabled,
    brushRadius = brushRadius
  }
end
M.serialize = serialize
M.deserialize = deserialize
M.onSerialize = serialize
M.onDeserialized = deserialize
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleSpawned = onVehicleSpawned

return M
