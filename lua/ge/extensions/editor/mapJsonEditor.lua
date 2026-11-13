-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Editor for the level navgraph file levels/<level>/map.json. It holds manual road segments:
-- named, ordered chains of BeamNGWaypoint objects with drivability, direction and lane overrides.
-- The waypoints themselves are scene objects, this file only references them by name. map.lua
-- watches the file and reloads the navgraph when it is written.

local M = {}

local ffi = require('ffi')
local im = ui_imgui
local logTag = 'mapJsonEditor'
local toolWindowName = 'mapJsonEditor'
local editModeName = 'Edit Map Json'

-- written in this order, remaining keys are appended so nothing gets dropped on save
local knownKeys = { 'drivability', 'oneWay', 'flipDirection', 'autoLanes', 'lanesLeft', 'lanesRight',
                    'autoJunction', 'hiddenInNavi', 'gatedRoad', 'type', 'speedLimit' }

local data                     -- { segments = { [name] = segment } }
local order = {}               -- segment names, sorted, for a stable list
local filePath
local dirty = false
local selSeg                   -- selected segment name
local selNode                  -- selected index into the segment node list
local pickedWp                 -- last waypoint clicked that is not part of the selection
local waypoints = {}           -- name -> { pos, radius } of every BeamNGWaypoint in the scene
local missingCount = {}        -- segment name -> nodes that have no waypoint in the scene
local mouseInfo = {}
local prevSeg

local nameBuffer = im.ArrayChar(128, "")
local typeBuffer = im.ArrayChar(64, "")
local drivabilityPtr = im.FloatPtr(1)
local speedLimitPtr = im.FloatPtr(0)
local lanesLeftPtr = im.IntPtr(0)
local lanesRightPtr = im.IntPtr(0)
local oneWayPtr = im.BoolPtr(false)
local flipPtr = im.BoolPtr(false)
local hiddenPtr = im.BoolPtr(false)
local gatedPtr = im.BoolPtr(false)
local autoLanesPtr = im.BoolPtr(true)
local autoJunctionPtr = im.BoolPtr(true)
local showAllWpPtr = im.BoolPtr(true)
local showAllSegPtr = im.BoolPtr(true)
local drawRadiusPtr = im.FloatPtr(500)
local segClipper = im.ImGuiListClipper()

local colSeg = ColorF(0.35, 0.65, 1, 1)
local colSegSel = ColorF(1, 0.45, 0, 1)
local colStart = ColorF(0.2, 0.9, 0.3, 1)
local colEnd = ColorF(0.95, 0.2, 0.2, 1)
local colNode = ColorF(1, 1, 1, 0.9)
local colNodeSel = ColorF(1, 0.45, 0, 1)
local colFreeWp = ColorF(0.6, 0.6, 0.7, 0.5)
local colText = ColorF(1, 1, 1, 1)
local colTextBg = ColorI(0, 0, 0, 192)

-- ==================== data ====================

local function levelDir()
  return (path.split(getMissionFilename()) or '')
end

local function defaultFilePath()
  local d = levelDir()
  return d ~= '' and (d .. 'map.json') or nil
end

local function refreshWaypoints()
  waypoints = {}
  for _, name in ipairs(scenetree.findClassObjects('BeamNGWaypoint') or {}) do
    local o = scenetree.findObject(name)
    if o then
      waypoints[name] = { pos = vec3(o:getPosition()), radius = getSceneWaypointRadius(o) }
    end
  end
end

local function refreshMissing()
  missingCount = {}
  if not data then return end
  for name, seg in pairs(data.segments) do
    local c = 0
    for _, n in ipairs(seg.nodes) do
      if not waypoints[n] then c = c + 1 end
    end
    missingCount[name] = c
  end
end

local function rebuildOrder()
  order = {}
  if not data then return end
  for name in pairs(data.segments) do order[#order + 1] = name end
  table.sort(order)
end

-- map.lua also accepts "wp1, wp3-wp6" shorthand, expand it so editing is uniform
local function expandNodeString(s)
  local out = {}
  for _, part in ipairs(split(s, ',')) do
    local range = split(trim(part), '-')
    if #range == 1 then
      out[#out + 1] = trim(range[1])
    elseif #range == 2 then
      local prefix = string.match(range[1], '[^%d]+')
      local from = tonumber(string.match(range[1], '%d+'))
      local to = tonumber(string.match(range[2], '%d+'))
      if prefix and from and to then
        for k = from, to do out[#out + 1] = prefix .. tostring(k) end
      end
    end
  end
  return out
end

local function clearSelection()
  selSeg, selNode, pickedWp = nil, nil, nil
end

local function newData()
  data = { segments = {} }
  filePath = defaultFilePath()
  clearSelection()
  rebuildOrder()
  refreshMissing()
  dirty = true
end

local function loadFile(fp)
  fp = fp or defaultFilePath()
  if not fp then
    log('E', logTag, 'no level loaded, cannot resolve the map.json path')
    return false
  end
  local d = jsonReadFile(fp)
  if type(d) ~= 'table' then
    log('W', logTag, 'cannot read ' .. tostring(fp))
    return false
  end
  d.segments = d.segments or {}
  for _, seg in pairs(d.segments) do
    if type(seg.nodes) == 'string' then seg.nodes = expandNodeString(seg.nodes) end
    seg.nodes = seg.nodes or {}
  end
  data = d
  filePath = fp
  clearSelection()
  rebuildOrder()
  refreshWaypoints()
  refreshMissing()
  dirty = false
  log('I', logTag, string.format('loaded %s: %d segments', fp, #order))
  return true
end

local function encodeValue(v)
  if type(v) == 'string' then return jsonEncode(v) end
  if type(v) == 'number' then
    -- keeps float32 slider noise out of the file
    if v == math.floor(v) then return string.format('%d', v) end
    return (string.format('%.4f', v):gsub('0+$', ''))
  end
  return tostring(v)
end

-- hand written so the file keeps the compact shipped layout (one line per node list)
local function serialize()
  local out = { '{\n  "segments" : {\n' }
  for i, name in ipairs(order) do
    local seg = data.segments[name]
    local nodes = {}
    for j, n in ipairs(seg.nodes) do nodes[j] = jsonEncode(n) end
    local lines = { '      "nodes" : [' .. table.concat(nodes, ', ') .. ']' }
    local written = { nodes = true }
    for _, k in ipairs(knownKeys) do
      if seg[k] ~= nil then
        lines[#lines + 1] = '      "' .. k .. '" : ' .. encodeValue(seg[k])
        written[k] = true
      end
    end
    local extra = {}
    for k in pairs(seg) do
      if not written[k] then extra[#extra + 1] = k end
    end
    table.sort(extra)
    for _, k in ipairs(extra) do
      lines[#lines + 1] = '      "' .. k .. '" : ' .. encodeValue(seg[k])
    end
    out[#out + 1] = '    ' .. jsonEncode(name) .. ' : {\n' .. table.concat(lines, ',\n') .. '\n    }'
    out[#out + 1] = (i < #order) and ',\n\n' or '\n'
  end
  out[#out + 1] = '  }\n}\n'
  return table.concat(out)
end

local function saveFile(fp)
  if not data then return end
  fp = fp or filePath or defaultFilePath()
  if not fp then return end
  if not writeFile(fp, serialize()) then
    log('E', logTag, 'failed to write ' .. tostring(fp))
    return
  end
  filePath = fp
  dirty = false
  log('I', logTag, string.format('saved %s (%d segments), navgraph reloads on file change', fp, #order))
end

-- ==================== segment & node editing ====================

local function selectedSegment()
  return selSeg and data and data.segments[selSeg] or nil
end

local function syncPropertyBuffers()
  if prevSeg == selSeg then return end
  prevSeg = selSeg
  local seg = selectedSegment()
  ffi.copy(nameBuffer, selSeg or "")
  if not seg then return end
  drivabilityPtr[0] = seg.drivability or 1
  speedLimitPtr[0] = seg.speedLimit or 0
  lanesLeftPtr[0] = seg.lanesLeft or 0
  lanesRightPtr[0] = seg.lanesRight or 0
  oneWayPtr[0] = seg.oneWay and true or false
  flipPtr[0] = seg.flipDirection and true or false
  hiddenPtr[0] = seg.hiddenInNavi and true or false
  gatedPtr[0] = seg.gatedRoad and true or false
  autoLanesPtr[0] = seg.autoLanes ~= false
  autoJunctionPtr[0] = seg.autoJunction ~= false
  ffi.copy(typeBuffer, seg.type or "")
end

local function selectSegment(name, nodeIdx)
  selSeg = name
  selNode = nodeIdx
  pickedWp = nil
end

local function uniqueName(base)
  if not data.segments[base] then return base end
  local i = 2
  while data.segments[base .. '_' .. i] do i = i + 1 end
  return base .. '_' .. i
end

local function newSegment(nodes)
  local name = uniqueName('segment')
  data.segments[name] = { nodes = nodes or {}, drivability = 1 }
  rebuildOrder()
  refreshMissing()
  dirty = true
  selectSegment(name, nil)
end

local function duplicateSegment()
  local seg = selectedSegment()
  if not seg then return end
  local copy = { nodes = {} }
  for k, v in pairs(seg) do
    if k ~= 'nodes' then copy[k] = v end
  end
  for i, n in ipairs(seg.nodes) do copy.nodes[i] = n end
  local name = uniqueName(selSeg)
  data.segments[name] = copy
  rebuildOrder()
  refreshMissing()
  dirty = true
  selectSegment(name, nil)
end

local function deleteSegment()
  if not selSeg then return end
  data.segments[selSeg] = nil
  rebuildOrder()
  refreshMissing()
  dirty = true
  clearSelection()
end

local function renameSegment(newName)
  newName = trim(newName or '')
  if newName == '' or newName == selSeg or not selSeg then return end
  if data.segments[newName] then
    log('W', logTag, 'a segment named ' .. newName .. ' already exists')
    return
  end
  data.segments[newName] = data.segments[selSeg]
  data.segments[selSeg] = nil
  rebuildOrder()
  refreshMissing()
  dirty = true
  selSeg = newName
  prevSeg = newName
end

-- inserts after the selected node, or appends
local function addNode(wpName)
  if not wpName then return end
  local seg = selectedSegment()
  if not seg then
    newSegment({ wpName })
    selNode = 1
    return
  end
  local at = (selNode or #seg.nodes) + 1
  table.insert(seg.nodes, at, wpName)
  selNode = at
  refreshMissing()
  dirty = true
end

local function removeNode()
  local seg = selectedSegment()
  if not seg or not selNode then return end
  table.remove(seg.nodes, selNode)
  selNode = math.min(selNode, #seg.nodes)
  if selNode < 1 then selNode = nil end
  refreshMissing()
  dirty = true
end

local function moveNode(delta)
  local seg = selectedSegment()
  if not seg or not selNode then return end
  local to = selNode + delta
  if to < 1 or to > #seg.nodes then return end
  seg.nodes[selNode], seg.nodes[to] = seg.nodes[to], seg.nodes[selNode]
  selNode = to
  dirty = true
end

local function reverseNodes()
  local seg = selectedSegment()
  if not seg then return end
  local n = #seg.nodes
  for i = 1, math.floor(n / 2) do
    seg.nodes[i], seg.nodes[n - i + 1] = seg.nodes[n - i + 1], seg.nodes[i]
  end
  if selNode then selNode = n - selNode + 1 end
  dirty = true
end

-- BeamNGWaypoints currently selected in the scene tree, in selection order
local function selectedSceneWaypoints()
  local out = {}
  for _, id in ipairs(editor.selection and editor.selection.object or {}) do
    local o = scenetree.findObjectById(id)
    if o and o.getClassName and o:getClassName() == 'BeamNGWaypoint' then
      out[#out + 1] = o:getName()
    end
  end
  return out
end

local function segmentContaining(wpName)
  for _, name in ipairs(order) do
    for i, n in ipairs(data.segments[name].nodes) do
      if n == wpName then return name, i end
    end
  end
  return nil
end

-- ==================== mouse ====================

local function updateMouseInfo()
  mouseInfo.camPos = core_camera.getPosition()
  local ray = getCameraMouseRay()
  mouseInfo.rayDir = vec3(ray.dir)
  mouseInfo.down = im.IsMouseClicked(0) and not im.GetIO().WantCaptureMouse
end

local function waypointUnderMouse()
  if not mouseInfo.camPos or not mouseInfo.rayDir then return nil end
  local radius = drawRadiusPtr[0]
  local rayLen = mouseInfo.rayDir:length()
  local best, bestDist = nil, math.huge
  for name, wp in pairs(waypoints) do
    local d = wp.pos - mouseInfo.camPos
    local distToCam = d:length()
    if distToCam < radius and distToCam < bestDist then
      local rayDist = d:cross(mouseInfo.rayDir):length() / rayLen
      if rayDist <= math.max(wp.radius, 1) then
        bestDist, best = distToCam, name
      end
    end
  end
  return best
end

-- ==================== 3d display ====================

local drawRadiusSq = 0

local function inRange(pos)
  local c = mouseInfo.camPos
  if not c then return false end
  local dx, dy, dz = pos.x - c.x, pos.y - c.y, pos.z - c.z
  return dx * dx + dy * dy + dz * dz <= drawRadiusSq
end

local function drawSegment(name, isSel)
  local seg = data.segments[name]
  local nodes = seg.nodes
  local col = isSel and colSegSel or colSeg
  local prev
  for _, n in ipairs(nodes) do
    local wp = waypoints[n]
    if wp then
      if prev and (inRange(wp.pos) or inRange(prev)) then
        debugDrawer:drawLineInstance(prev, wp.pos, isSel and 5 or 3, col)
      end
      prev = wp.pos
    end
  end
  if not isSel then return end

  for i, n in ipairs(nodes) do
    local wp = waypoints[n]
    if wp and inRange(wp.pos) then
      local c = colNode
      if selNode == i then c = colNodeSel
      elseif i == 1 then c = colStart
      elseif i == #nodes then c = colEnd end
      debugDrawer:drawSphere(wp.pos, math.max(wp.radius * 0.6, 0.4), c)
      debugDrawer:drawTextAdvanced(wp.pos, String(i .. ': ' .. n), colText, true, false, colTextBg)
    end
  end
end

local function draw3D()
  if not data or not mouseInfo.camPos then return end
  drawRadiusSq = drawRadiusPtr[0] * drawRadiusPtr[0]

  if showAllWpPtr[0] then
    for _, wp in pairs(waypoints) do
      if inRange(wp.pos) then
        debugDrawer:drawSphere(wp.pos, math.max(wp.radius * 0.35, 0.25), colFreeWp)
      end
    end
  end

  if showAllSegPtr[0] then
    for _, name in ipairs(order) do
      if name ~= selSeg then drawSegment(name, false) end
    end
  end
  if selSeg and data.segments[selSeg] then drawSegment(selSeg, true) end

  if pickedWp and waypoints[pickedWp] then
    local wp = waypoints[pickedWp]
    debugDrawer:drawSphere(wp.pos, math.max(wp.radius * 0.8, 0.6), colStart)
    debugDrawer:drawTextAdvanced(wp.pos, String(pickedWp), colText, true, false, colTextBg)
  end
end

-- ==================== gui ====================

local function inEditMode()
  return editor.editMode and editor.editMode.displayName == editModeName
end

local function segmentListGui()
  im.Text(string.format("Segments: %d", #order))
  im.SameLine()
  if im.Button("New") then newSegment(selectedSceneWaypoints()) end
  im.tooltip("Creates a segment from the BeamNGWaypoints selected in the scene tree, or an empty one")
  im.SameLine()
  if not selSeg then im.BeginDisabled() end
  if im.Button("Duplicate") then duplicateSegment() end
  im.SameLine()
  if im.Button("Delete") then deleteSegment() end
  if not selSeg then im.EndDisabled() end

  im.BeginChild1("segList", im.ImVec2(0, 170), true)
  im.ImGuiListClipper_Begin(segClipper, #order)
  while im.ImGuiListClipper_Step(segClipper) do
    for i = segClipper.DisplayStart + 1, segClipper.DisplayEnd do
      local name = order[i]
      local seg = name and data.segments[name]
      if seg then
        local broken = (missingCount[name] or 0) > 0
        if broken then im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 0.4, 0.4, 1)) end
        if im.Selectable1(string.format("%s (%d)##sg%d", name, #seg.nodes, i), name == selSeg) then
          selectSegment(name, nil)
        end
        if broken then im.PopStyleColor() end
      end
    end
  end
  im.EndChild()
end

local function propertiesGui(seg)
  im.PushItemWidth(200)
  if im.InputText("Name##segname", nameBuffer, 128, im.InputTextFlags_EnterReturnsTrue) then
    renameSegment(ffi.string(nameBuffer))
  end
  im.tooltip("Press enter to rename")

  if im.SliderFloat("Drivability##segdrv", drivabilityPtr, 0, 1, "%.2f") then
    seg.drivability = drivabilityPtr[0]
    dirty = true
  end
  im.tooltip("How willing the AI is to use this road, 1 is a normal road, 0 disables it")
  im.PopItemWidth()

  if im.Checkbox("One way", oneWayPtr) then
    seg.oneWay = oneWayPtr[0] or nil
    dirty = true
  end
  im.SameLine()
  if im.Checkbox("Flip direction", flipPtr) then
    seg.flipDirection = flipPtr[0] or nil
    dirty = true
  end
  im.tooltip("Swaps the travel direction, the node order defines it otherwise")

  if im.Checkbox("Hidden in navi", hiddenPtr) then
    seg.hiddenInNavi = hiddenPtr[0] or nil
    dirty = true
  end
  im.SameLine()
  if im.Checkbox("Gated road", gatedPtr) then
    seg.gatedRoad = gatedPtr[0] or nil
    dirty = true
  end
  im.tooltip("Marks the road private, traffic avoids it")

  if im.Checkbox("Auto junction", autoJunctionPtr) then
    seg.autoJunction = autoJunctionPtr[0] and nil or false
    dirty = true
  end
  im.tooltip("Off keeps the nodes from merging with roads they overlap")

  if im.Checkbox("Auto lanes", autoLanesPtr) then
    if autoLanesPtr[0] then
      seg.autoLanes = nil
    else
      seg.autoLanes = false
      -- manual lanes with no counts would build an empty lane string
      seg.lanesLeft = seg.lanesLeft or 1
      seg.lanesRight = seg.lanesRight or 1
      lanesLeftPtr[0] = seg.lanesLeft
      lanesRightPtr[0] = seg.lanesRight
    end
    dirty = true
  end
  if not autoLanesPtr[0] then
    im.PushItemWidth(120)
    if editor.uiInputInt("Lanes left##segll", lanesLeftPtr, 1, 1, nil, nil) then
      if lanesLeftPtr[0] < 0 then lanesLeftPtr[0] = 0 end
      seg.lanesLeft = lanesLeftPtr[0]
      dirty = true
    end
    im.SameLine()
    if editor.uiInputInt("Lanes right##seglr", lanesRightPtr, 1, 1, nil, nil) then
      if lanesRightPtr[0] < 0 then lanesRightPtr[0] = 0 end
      seg.lanesRight = lanesRightPtr[0]
      dirty = true
    end
    im.PopItemWidth()
  end

  im.PushItemWidth(120)
  if editor.uiInputFloat("Speed limit##segspd", speedLimitPtr, 1, 5, "%.1f m/s", nil) then
    seg.speedLimit = speedLimitPtr[0] > 0 and speedLimitPtr[0] or nil
    dirty = true
  end
  im.tooltip("0 removes the limit from the file")
  im.SameLine()
  if im.InputText("Type##segtype", typeBuffer, 64) then
    local t = trim(ffi.string(typeBuffer))
    seg.type = t ~= '' and t or nil
    dirty = true
  end
  im.PopItemWidth()
end

local function nodesGui(seg)
  local missing = missingCount[selSeg] or 0
  if missing > 0 then
    im.TextColored(im.ImVec4(1, 0.4, 0.4, 1), string.format("%d node(s) have no BeamNGWaypoint in the scene", missing))
  end
  im.Text(string.format("Nodes: %d", #seg.nodes))
  im.SameLine()
  if im.Button("Add scene selection") then
    for _, n in ipairs(selectedSceneWaypoints()) do addNode(n) end
  end
  im.tooltip("Appends the BeamNGWaypoints selected in the scene tree")
  im.SameLine()
  if im.Button("Reverse") then reverseNodes() end

  im.BeginChild1("nodeList", im.ImVec2(0, 150), true)
  for i, n in ipairs(seg.nodes) do
    local exists = waypoints[n] ~= nil
    if not exists then im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 0.4, 0.4, 1)) end
    if im.Selectable1(string.format("%d: %s%s##nd%d", i, n, exists and "" or "  (missing)", i), selNode == i) then
      selNode = i
    end
    if not exists then im.PopStyleColor() end
  end
  im.EndChild()

  if not selNode then
    im.TextDisabled("No node selected")
    return
  end
  if im.Button("Up") then moveNode(-1) end
  im.SameLine()
  if im.Button("Down") then moveNode(1) end
  im.SameLine()
  if im.Button("Remove") then removeNode() end
  im.SameLine()
  if im.Button("Select in scene") then
    local wpName = seg.nodes[selNode]
    local o = wpName and scenetree.findObject(wpName)
    if o then editor.selectObjectById(o:getId()) end
  end
  im.tooltip("Selects the waypoint object so the normal gizmo can move it")
end

local function fileMenuGui()
  if not im.BeginMenuBar() then return end
  if im.BeginMenu("File") then
    if im.MenuItem1("Open level map.json") then loadFile(defaultFilePath()) end
    if im.MenuItem1("New") then newData() end
    if im.MenuItem1("Open...") then
      editor_fileDialog.openFile(
        function(d) loadFile(d.filepath) end,
        {{'map.json files', '.json'}},
        false,
        levelDir()
      )
    end
    if data == nil then im.BeginDisabled() end
    if im.MenuItem1("Save") then saveFile(nil) end
    if im.MenuItem1("Save As...") then
      editor_fileDialog.saveFile(
        function(d) saveFile(d.filepath) end,
        {{'map.json files', '.json'}},
        false,
        levelDir(),
        "File already exists.\nDo you want to overwrite the file?"
      )
    end
    if im.MenuItem1("Reload from disk") then loadFile(filePath) end
    if data == nil then im.EndDisabled() end
    im.EndMenu()
  end
  im.EndMenuBar()
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Map Json Editor", im.WindowFlags_MenuBar) then
    fileMenuGui()

    if not data then
      im.TextWrapped("No map.json open. It holds the level's manual navgraph segments and lives next to the level, as " .. tostring(defaultFilePath()))
      if im.Button("Open level map.json") then loadFile(defaultFilePath()) end
      im.SameLine()
      if im.Button("New") then newData() end
      editor.endWindow()
      return
    end

    im.TextDisabled(tostring(filePath) .. (dirty and " *" or ""))
    im.PushStyleColor2(im.Col_Button, im.ImVec4(0.2, 0.7, 0.3, 1.0))
    im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.3, 0.8, 0.4, 1.0))
    im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.1, 0.6, 0.2, 1.0))
    if im.Button("SAVE", im.ImVec2(im.GetContentRegionAvailWidth(), 28)) then saveFile(nil) end
    im.PopStyleColor(3)

    if not inEditMode() then
      if im.Button("Switch to Map Json editmode", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
        editor.selectEditMode(editor.editModes.mapJsonEditMode)
      end
    end

    im.Checkbox("All segments", showAllSegPtr)
    im.SameLine()
    im.Checkbox("All waypoints", showAllWpPtr)
    im.SameLine()
    if im.Button("Rescan waypoints") then
      refreshWaypoints()
      refreshMissing()
    end
    im.PushItemWidth(180)
    im.SliderFloat("Draw radius", drawRadiusPtr, 50, 5000, "%.0f m")
    im.PopItemWidth()
    im.tooltip("Only waypoints within this distance from the camera are drawn and pickable")

    updateMouseInfo()
    draw3D()

    if inEditMode() and mouseInfo.down then
      local wpName = waypointUnderMouse()
      if wpName then
        if editor.keyModifiers.ctrl then
          addNode(wpName)
        else
          local segName, idx = segmentContaining(wpName)
          if segName then
            selectSegment(segName, idx)
          else
            selNode = nil
            pickedWp = wpName
          end
        end
      end
    end

    segmentListGui()
    syncPropertyBuffers()

    local seg = selectedSegment()
    if not seg then
      im.TextDisabled("No segment selected")
      if pickedWp then
        im.Text("Picked waypoint: " .. pickedWp)
        im.SameLine()
        if im.Button("New segment from it") then newSegment({ pickedWp }) end
      end
      editor.endWindow()
      return
    end

    im.Separator()
    propertiesGui(seg)
    im.Separator()
    nodesGui(seg)
    im.Separator()
    im.TextDisabled("Ctrl+LMB adds the waypoint under the cursor, LMB selects its segment")
  end
  editor.endWindow()
end

-- ==================== lifecycle ====================

local function show()
  editor.showWindow(toolWindowName)
  editor.selectEditMode(editor.editModes.mapJsonEditMode)
  if not data then loadFile(defaultFilePath()) end
  refreshWaypoints()
  refreshMissing()
end

local function onActivate()
  refreshWaypoints()
  refreshMissing()
end

local function onEditorInitialized()
  editor.editModes.mapJsonEditMode = {
    displayName = editModeName,
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = nop,
    auxShortcuts = {},
  }
  editor.editModes.mapJsonEditMode.auxShortcuts[editor.AuxControl_LMB] = "Select segment"
  editor.editModes.mapJsonEditMode.auxShortcuts[bit.bor(editor.AuxControl_Ctrl, editor.AuxControl_LMB)] = "Add waypoint to segment"
  editor.registerWindow(toolWindowName, im.ImVec2(430, 700))
  editor.addWindowMenuItem("Map Json Editor", function() show() end, {groupMenuName = 'Roads'})
end

local function onEditorToolWindowHide(windowName)
  if windowName == toolWindowName then
    editor.selectEditMode(editor.editModes.objectSelect)
  end
end

local function onWindowGotFocus(windowName)
  if windowName == toolWindowName then
    editor.selectEditMode(editor.editModes.mapJsonEditMode)
  end
end

local function onEditorExitLevel()
  data = nil
  filePath = nil
  dirty = false
  order = {}
  waypoints = {}
  missingCount = {}
  clearSelection()
end

local function onSerialize()
  return { data = data, filePath = filePath, dirty = dirty }
end

local function onDeserialized(d)
  if not d then return end
  data = d.data
  filePath = d.filePath
  dirty = d.dirty or false
  rebuildOrder()
  refreshWaypoints()
  refreshMissing()
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onEditorToolWindowHide = onEditorToolWindowHide
M.onWindowGotFocus = onWindowGotFocus
M.onEditorExitLevel = onEditorExitLevel
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.show = show
M.loadFile = loadFile
M.saveFile = saveFile

return M
