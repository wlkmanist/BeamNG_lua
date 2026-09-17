-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local defaultSpeed, speedMin, speedMax = 1.0, 0.0, 10.0
local defaultDepth = 10.0

local maxRayDist = 10000 -- The maximum distance to cast the ray.
local zExtra = 0.05 -- Extra height to add to the ribbon nodes to avoid z-fighting with the river surface.

local typeStr_quad2D_top = 'Four Emitters - 2D (Over Top Surface Only)' -- The type strings for the different source types.
local typeStr_quad2D_bottom = 'Four Emitters - 2D (Over Bottom Surface Only)'
local typeStr_quad3D = 'Four Emitters - 3D (Over Whole Volume)'
local typeStr_ambient = 'Single Emitter Only'

local defaultFrontEventName = 'event:>Ambient>Water>River' -- The default event path for the quad emitters.
local defaultRearEventName = 'event:>Ambient>Water>River'
local defaultLeftEventName = 'event:>Ambient>Water>River'
local defaultRightEventName = 'event:>Ambient>Water>River'
local defaultAmbientEventName = 'event:>Ambient>Water>River' -- The default event path for the ambient emitter.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local audioRibbon = require('core/audioRibbon')
local input = require('editor/toolUtilities/ribbonInput')
local render = require('editor/toolUtilities/render')
local util = require('editor/toolUtilities/util')
local style = require('editor/toolUtilities/style')

-- Module constants.
local im = ui_imgui
local min, max, floor, sqrt, huge, abs = math.min, math.max, math.floor, math.sqrt, math.huge, math.abs
local toolWinName, toolWinSize = 'audioRibbonEditor', im.ImVec2(500, 500) -- The main tool window of the editor. The main UI entry point.
local globalDown = vec3(0, 0, -1)
local cols = style.getImguiCols('crystal')
local iconsBig, iconsSmall = im.ImVec2(36, 36), im.ImVec2(24, 24)

-- Module state.
local isAudioRibbonEditor = false -- A flag which indicates if this tool is active, or not.
local isFirstTime = true -- A flag which indicates if this is the first time the editor is opened.
local isLockShape = false -- A flag which indicates if the shape of the mesh spline is locked (rigid translation), or not.
local selectedRibbonIdx = 1 -- The index of the currently selected ribbon (in the list box).
local selectedNodeIdx = 1 -- The index of the selected node (on the selected ribbon).
local placedLeftNode = nil -- The left node that was placed.
local bestCursorSeg = 1 -- The best cursor segment for the selected ribbon.
local isDragging = false -- A flag which indicates if the node is being dragged, or not.
local isGizmoActive = false -- A flag which indicates if the gizmo is active, or not.
local hoveredRibbonIdx = nil -- The ribbon index currently hovered in the list box, if any.
local ribbonSearchBuf = im.ArrayChar(64, "") -- Search bar input buffer for filtering the ribbons list.
local ribbonSearchWidgetId = 0 -- Increment to force ImGui to forget InputText internal state when clearing the search box.
local ribbonUiOrder = {} -- Cached sorted order: array of ribbon indices.
local ribbonUiFiltered = {} -- Cached filtered order (subset of ribbonUiOrder).
local isRibbonUiDirty = true -- Whether cached order needs rebuilding.
local lastRibbonFilterStr = '' -- Cached last filter string (lowercase) to avoid rebuilding filter every frame.
local masterSpeed = im.FloatPtr(defaultSpeed) -- Imgui binding for the speed slider.
local masterDepth = defaultDepth -- Default depth for new ribbon nodes.
local ambientEventBinding = im.ArrayChar(128, defaultAmbientEventName) -- The event binding for the ambient emitter.
local frontEventBinding = im.ArrayChar(128, defaultFrontEventName) -- The event binding for the front emitter.
local rearEventBinding = im.ArrayChar(128, defaultRearEventName) -- The event binding for the rear emitter.
local rightEventBinding = im.ArrayChar(128, defaultRightEventName) -- The event binding for the right emitter.
local leftEventBinding = im.ArrayChar(128, defaultLeftEventName) -- The event binding for the left emitter.
local nameBinding = im.ArrayChar(128, '')
local tmpPos = vec3()
local out = {
  ribbonIdx = 1,
  nodeIdx = 1,
  isGizmoActive = false,
  isLockShape = isLockShape,
}


local function rebuildRibbonUiOrder(ribbons)
  table.clear(ribbonUiOrder)
  local ctr = 1
  for i = 1, #ribbons do
    ribbonUiOrder[ctr] = i
    ctr = ctr + 1
  end
  table.sort(ribbonUiOrder, function(a, b)
    local ra, rb = ribbons[a], ribbons[b]
    local na = string.lower(ra.name or '')
    local nb = string.lower(rb.name or '')
    if na == nb then
      return (ra.persistantId or '') < (rb.persistantId or '')
    end
    return na < nb
  end)
  isRibbonUiDirty = false
end

local function rebuildRibbonUiFiltered(ribbons, filterStr)
  table.clear(ribbonUiFiltered)
  local ctr = 1
  if filterStr == '' then
    return
  end
  for i = 1, #ribbonUiOrder do
    local ribbonIdx = ribbonUiOrder[i]
    local nameLower = string.lower((ribbons[ribbonIdx] and ribbons[ribbonIdx].name) or '')
    if string.find(nameLower, filterStr, 1, true) then
      ribbonUiFiltered[ctr] = ribbonIdx
      ctr = ctr + 1
    end
  end
end

local function markRibbonUiDirty()
  isRibbonUiDirty = true
end

-- Set the ui bindings appropriately, if there are any ribbons.
local function updateUIBindings()
  local ribbons = audioRibbon.getRibbons()
  if #ribbons > 0 then
    local firstRibbon = ribbons[1]
    masterSpeed = im.FloatPtr(firstRibbon.speed)
    masterDepth = firstRibbon.depths[1] or defaultDepth
    local emitters = firstRibbon.emitters
    ambientEventBinding = im.ArrayChar(128, emitters[1].eventNameStr)
    frontEventBinding = im.ArrayChar(128, emitters[2].eventNameStr)
    rearEventBinding = im.ArrayChar(128, emitters[3].eventNameStr)
    rightEventBinding = im.ArrayChar(128, emitters[4].eventNameStr)
    leftEventBinding = im.ArrayChar(128, emitters[5].eventNameStr)
  end
end

-- Deep copies the state of all ribbons.
local function copyRibbonsState()
  local ribbons, ribbonsCopy = audioRibbon.getRibbons(), {}
  for i = 1, #ribbons do
    -- Deep copy the geometry data.
    local ribbon = ribbons[i]
    local nodes, depths, widths = ribbon.nodes, ribbon.depths, ribbon.widths
    local nodesCopy = {}
    for j = 1, #nodes do
      nodesCopy[j] = vec3(nodes[j])
    end
    local depthsCopy = deepcopy(depths)
    local widthsCopy = deepcopy(widths)

    -- Deep copy the emitters data.
    local emittersCopy = {}
    if ribbon and ribbon.emitters and ribbon.emitters[1] and ribbon.emitters[1].bestSeg then
      local emitters = ribbon.emitters
      local em1, em2, em3, em4, em5 = emitters[1], emitters[2], emitters[3], emitters[4], emitters[5]
      emittersCopy[1] = { bestSeg = em1.bestSeg, pos = vec3(em1.pos), bN = em1.bN, eventNameStr = em1.eventNameStr }
      emittersCopy[2] = { bestSeg = em2.bestSeg, pos = vec3(em2.pos), bN = em2.bN, eventNameStr = em2.eventNameStr }
      emittersCopy[3] = { bestSeg = em3.bestSeg, pos = vec3(em3.pos), bN = em3.bN, eventNameStr = em3.eventNameStr }
      emittersCopy[4] = { bestSeg = em4.bestSeg, pos = vec3(em4.pos), bN = em4.bN, eventNameStr = em4.eventNameStr }
      emittersCopy[5] = { bestSeg = em5.bestSeg, pos = vec3(em5.pos), bN = em5.bN, eventNameStr = em5.eventNameStr }
    end

    -- Deep copy the ribbon properties data and populate the copy.
    ribbonsCopy[i] = {
      persistantId = ribbon.persistantId,
      name = ribbon.name,
      isMuteA = ribbon.isMuteA,
      isMuteB = ribbon.isMuteB,
      isMuteC = ribbon.isMuteC,
      isMuteD = ribbon.isMuteD,
      isEnabled = ribbon.isEnabled,
      isAmbient = ribbon.isAmbient,
      isUpRibbon = ribbon.isUpRibbon,
      isTopActive = ribbon.isTopActive,
      isQuadAndVolume = ribbon.isQuadAndVolume,
      numSegs = ribbon.numSegs,
      speed = ribbon.speed,
      nodes = nodesCopy,
      depths = depthsCopy,
      widths = widthsCopy,
      emitters = emittersCopy,
    }
  end
  return ribbonsCopy
end

-- Undo/redo core functionality for ribbon edits.
local function undoRedoCore(data)
  audioRibbon.setRibbons(data)
  audioRibbon.recomputeMap()
  audioRibbon.clearAllSFXEmitters() -- Ensure all the active SFX emitter objects are removed. They will be recreated on the next frame.
  audioRibbon.clearNearFarLists() -- Ensure all the near/far lists are cleared. They will be recreated on the next frame.
  markRibbonUiDirty()
end

-- Undo/redo callbacks for ribbon edits.
local function editStateUndo(data) undoRedoCore(data.old) end
local function editStateRedo(data) undoRedoCore(data.new) end

-- Updates the event field for the given emitter.
local function updateEvent(ribbon)
  audioRibbon.clearAllSFXEmitters()
  ribbon.emitters[1].eventNameStr = ffi.string(ambientEventBinding)
  ribbon.emitters[2].eventNameStr = ffi.string(frontEventBinding)
  ribbon.emitters[3].eventNameStr = ffi.string(rearEventBinding)
  ribbon.emitters[4].eventNameStr = ffi.string(rightEventBinding)
  ribbon.emitters[5].eventNameStr = ffi.string(leftEventBinding)
end

-- Creates a new ribbon (without any nodes yet), and adds it to the ribbons list.
local function addNewRibbon()
  local ribbons, ribbonNames, nearList = audioRibbon.getRibbons(), audioRibbon.getRibbonNames(), audioRibbon.getNearList()
  local statePre = copyRibbonsState()
  local ribbonId = Engine.generateUUID()
  ribbons[#ribbons + 1] =
  {
    persistantId = ribbonId,
    name = 'New Ribbon ' .. tostring(#ribbons + 1),
    isVisible = false,
    isMuteA = false, isMuteB = false, isMuteC = false, isMuteD = false,
    isEnabled = true,
    isAmbient = false,
    isUpRibbon = true,
    isTopActive = true,
    isQuadAndVolume = false,
    nodes = {},
    widths = {},
    depths = {},
    numSegs = 0,
    speed = masterSpeed[0],
    emitters = {
      audioRibbon.createEmitterHost(defaultAmbientEventName),
      audioRibbon.createEmitterHost(defaultFrontEventName),
      audioRibbon.createEmitterHost(defaultRearEventName),
      audioRibbon.createEmitterHost(defaultRightEventName),
      audioRibbon.createEmitterHost(defaultLeftEventName) }
  }
  ribbonNames[ribbonId] = true
  editor.history:commitAction("Add New Ribbon", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
  nearList[ribbonId] = #ribbons
  markRibbonUiDirty()
end

-- Conform the ribbon to the terrain and river surfaces.
local function conformRibbonToTerrain()
  local ribbons = audioRibbon.getRibbons()
  local ribbon = ribbons[selectedRibbonIdx]
  if ribbon then
    local statePre = copyRibbonsState()

    -- Find all river objects in the level.
    local riverNames = scenetree.findClassObjects("River")
    local rivers = {}
    if riverNames then
      for i = 1, #riverNames do
        local river = scenetree.findObject(riverNames[i])
        if river then
          table.insert(rivers, river)
        end
      end
    end

    -- Get the water plane height, if it exists.
    local waterPlaneHeight = nil
    local waterPlanes = scenetree.findClassObjects("WaterPlane")
    if waterPlanes and waterPlanes[1] then
      local waterPlane = scenetree.findObject(waterPlanes[1])
      if waterPlane:getClassName() == "WaterPlane" then
        waterPlaneHeight = waterPlane:getPosition().z
      end
    end

    -- For each ribbon node, check both terrain and river surfaces.
    local terrain = core_terrain.getTerrain()
    local nodes = ribbon.nodes
    for i = 1, #nodes do
      -- Start with the terrain height.
      local node = nodes[i]
      local terrainHeight = terrain:getHeight(node) + zExtra
      local bestHeight = terrainHeight

      -- Check all rivers for closer surface hits.
      for _, river in ipairs(rivers) do
        local segmentsCount = river:getSegmentCount()
        for segmentIndex = 0, segmentsCount - 2 do
          -- Get the top surface corners from the current and next river segments (cross-sections).
          local c0, _, c2, _ = river:getSegmentSurfaceCorners(segmentIndex)
          local c0Next, _, c2Next, _ = river:getSegmentSurfaceCorners(segmentIndex + 1)

          -- Check if the vertical ray through the node intersects with the river surface triangles.
          -- [Use: (c0, c2, c0_next) and (c2, c2_next, c0_next) where c0,c2 are the top surface points.]
          tmpPos:set(node.x, node.y, maxRayDist)
          local hitDist1 = intersectsRay_Triangle(tmpPos, globalDown, c0, c2, c0Next)
          local hitDist2 = intersectsRay_Triangle(tmpPos, globalDown, c2, c2Next, c0Next)
          local riverHeight = nil
          if hitDist1 < maxRayDist then
            riverHeight = tmpPos.z - hitDist1
          elseif hitDist2 < maxRayDist then
            riverHeight = tmpPos.z - hitDist2
          end
          if riverHeight then -- If the river height is the highest found yet (including from terrain) then take it.
            if riverHeight > bestHeight then
              bestHeight = riverHeight
            end
          end
        end
      end

      -- Check against the water plane height, if it exists.
      if waterPlaneHeight and waterPlaneHeight > bestHeight then
        bestHeight = waterPlaneHeight
      end

      -- Set the node height to the best surface found (the highest of terrain, river, and water plane).
      ribbon.nodes[i].z = bestHeight
    end

    audioRibbon.updateRibbonData(ribbon)
    editor.history:commitAction(
      "Conform To Surface Below",
      { old = statePre, new = copyRibbonsState() },
      editStateUndo,
      editStateRedo)
  end
end

-- Initialisation callback.
local function onInit()
  if not audioRibbon.getRibbons() then
    audioRibbon.setRibbons({})
    audioRibbon.clearRibbonNames()
    audioRibbon.clearNearFarLists()
  end
end

local function renderSelectedEmitterType(selRibbon)
  im.Columns(2, "selRibbonColumns", false)
  im.SetColumnWidth(0, 40)
  im.TextColored(cols.greenB, 'Type:')
  im.SameLine()
  im.NextColumn()
  local typeStr = nil
  if selRibbon.isAmbient then
    typeStr = typeStr_ambient
  elseif selRibbon.isQuadAndVolume then
    typeStr = typeStr_quad3D
  elseif selRibbon.isTopActive then
    typeStr = typeStr_quad2D_top
  else
    typeStr = typeStr_quad2D_bottom
  end
  im.Text(typeStr)
  im.NextColumn()
  im.Separator()
  im.Columns(1)
end

local function renderSelectedEmitterMasterControls(icons, selRibbon)
  im.TextColored(cols.greenB, 'Master Controls:')
  im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
  im.Columns(2, "speedCols", false)
  im.SetColumnWidth(0, 30)
  if masterSpeed[0] ~= defaultSpeed then
    if editor.uiIconImageButton(icons.star_border, iconsSmall, cols.blueB, nil, nil, 'resetSpeedBtn') then
      masterSpeed = im.FloatPtr(defaultSpeed)
      selRibbon.speed = masterSpeed[0]
      audioRibbon.updateRibbonData(selRibbon)
    end
    im.tooltip("Reset to default")
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine()
  im.NextColumn()
  im.PushItemWidth(-1)
  if im.SliderFloat("###1051", masterSpeed, speedMin, speedMax, "Speed (m/s) = %.3f") then
    selRibbon.speed = masterSpeed[0]
    audioRibbon.updateRibbonData(selRibbon)
  end
  im.tooltip('Set the speed of the ribbon, in meters per second.')
  im.PopItemWidth()
  im.PopStyleVar()
  im.Columns(1)
end

local function renderSelectedEmitterMixControls(icons, selRibbon)
  local isAmbient = selRibbon.isAmbient
  im.Separator()
  im.Columns(1)
  im.TextColored(cols.greenB, 'Mix:')
  im.Columns(isAmbient and 1 or 4, "sfxEmittersColumns", true)
  if isAmbient then
    im.Text('Single Source:')
  else
    im.Text('Front:')
  end
  im.SameLine()
  local btnCol, btnIcon = cols.blueB, icons.volume_up
  if selRibbon.isMuteA then
    btnCol = cols.blueD
    btnIcon = icons.volume_mute
  end
  if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'muteButtonA') then
    local statePre = copyRibbonsState()
    selRibbon.isMuteA = not selRibbon.isMuteA
    editor.history:commitAction(selRibbon.isMuteA and "Mute Ambient" or "Unmute Ambient", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
  end
  if isAmbient then
    im.tooltip('Toggle mute/unmute the ambient emitter for this ribbon.')
  else
    im.tooltip('Toggle mute/unmute the front emitter for this ribbon.')
  end
  im.SameLine()
  im.NextColumn()

  if not isAmbient then
    im.Text('Rear:')
    im.SameLine()
    btnCol, btnIcon = cols.blueB, icons.volume_up
    if selRibbon.isMuteB then
      btnCol = cols.blueD
      btnIcon = icons.volume_mute
    end
    if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'muteButtonB') then
      local statePre = copyRibbonsState()
      selRibbon.isMuteB = not selRibbon.isMuteB
      editor.history:commitAction(selRibbon.isMuteB and "Mute Rear" or "Unmute Rear", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
    end
    im.tooltip('Toggle mute/unmute the rear emitter for this ribbon.')
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine()
  im.NextColumn()

  if not isAmbient then
    im.Text('Left:')
    im.SameLine()
    btnCol, btnIcon = cols.blueB, icons.volume_up
    if selRibbon.isMuteD then
      btnCol = cols.blueD
      btnIcon = icons.volume_mute
    end
    if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'muteButtonC') then
      local statePre = copyRibbonsState()
      selRibbon.isMuteD = not selRibbon.isMuteD
      editor.history:commitAction(selRibbon.isMuteD and "Mute Left" or "Unmute Left", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
    end
    im.tooltip('Toggle mute/unmute the left emitter for this ribbon.')
  else
    im.Dummy(iconsSmall)
  end
  im.SameLine()
  im.NextColumn()

  if not isAmbient then
    im.Text('Right:')
    im.SameLine()
    btnCol, btnIcon = cols.blueB, icons.volume_up
    if selRibbon.isMuteC then
      btnCol = cols.blueD
      btnIcon = icons.volume_mute
    end
    if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'muteButtonD') then
      local statePre = copyRibbonsState()
      selRibbon.isMuteC = not selRibbon.isMuteC
      editor.history:commitAction(selRibbon.isMuteC and "Mute Right" or "Unmute Right", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
    end
    im.tooltip('Toggle mute/unmute the right emitter for this ribbon.')
  else
    im.Dummy(iconsSmall)
  end
  im.NextColumn()
end

local function renderSelectedEmitterEventPaths(selRibbon)
  local isAmbient = selRibbon.isAmbient
  im.Separator()
  im.Columns(1)
  im.TextColored(cols.greenB, 'Event Paths:')

  im.Columns(2, "eventNameColumns", false)
  im.SetColumnWidth(0, 60)

  if not isAmbient then
    im.Text('Front:')
  else
    im.Text('Emitter:')
  end
  im.SameLine()
  im.NextColumn()
  im.PushItemWidth(-1)
  if not isAmbient then
    if im.InputText("###10113", frontEventBinding, 64) then
      updateEvent(selRibbon)
    end
    im.tooltip('Edit the event path for the front emitter of this ribbon.')
  else
    if im.InputText("###10114", ambientEventBinding, 64) then
      updateEvent(selRibbon)
    end
    im.tooltip('Edit the event path for the ambient emitter of this ribbon.')
  end
  im.NextColumn()
  im.PopItemWidth()

  if not isAmbient then
    im.Text('Rear:')
    im.SameLine()
    im.NextColumn()
    im.PushItemWidth(-1)
    if im.InputText("###1012", rearEventBinding, 64) then
      updateEvent(selRibbon)
    end
    im.tooltip('Edit the event path for the rear emitter of this ribbon.')
  else
    im.Dummy(iconsSmall)
  end
  im.NextColumn()
  im.PopItemWidth()

  if not isAmbient then
    im.Text('Left:')
    im.SameLine()
    im.NextColumn()
    im.PushItemWidth(-1)
    if im.InputText("###1013", leftEventBinding, 64) then
      updateEvent(selRibbon)
    end
    im.tooltip('Edit the event path for the left emitter of this ribbon.')
  else
    im.Dummy(iconsSmall)
  end
  im.NextColumn()
  im.PopItemWidth()

  if not isAmbient then
    im.Text('Right:')
    im.SameLine()
    im.NextColumn()
    im.PushItemWidth(-1)
    if im.InputText("###1014", rightEventBinding, 64) then
      updateEvent(selRibbon)
    end
    im.tooltip('Edit the event path for the right emitter of this ribbon.')
  else
    im.Dummy(iconsSmall)
  end
  im.NextColumn()
  im.PopItemWidth()
  im.Separator()
end

local function renderSelectedEmitterDetails(icons, selRibbon)
  if not selRibbon then
    return
  end
  renderSelectedEmitterType(selRibbon)
  renderSelectedEmitterMasterControls(icons, selRibbon)
  renderSelectedEmitterMixControls(icons, selRibbon)
  renderSelectedEmitterEventPaths(selRibbon)
end

-- Renders the tool window (called in every editor frame update callback).
local function renderToolWindow()
  local icons = editor.icons
  local ribbons, ribbonNames = audioRibbon.getRibbons(), audioRibbon.getRibbonNames()
  local statePre, btnCol, btnIcon
  local wasRibbonUiDirty, filterStr, uiList, ribbonIdx, ribbon, newName, selRibbon, selNodes
  if editor.beginWindow(toolWinName, "Dynamic Audio Ribbon Editor") then
    -- Top Button Row.
    im.Columns(5, "topBtnRowColumns", false)
    im.SetColumnWidth(0, 39)
    im.SetColumnWidth(1, 39)
    im.SetColumnWidth(2, 39)
    im.SetColumnWidth(3, 39)
    im.SetColumnWidth(4, 39)

    -- 'Add New ribbon' button.
    if editor.uiIconImageButton(icons.bSpline, iconsBig, cols.blueB, nil, nil, 'addNewRibbonButton') then
      addNewRibbon()
      im.ClearActiveID()
      ribbonSearchBuf = im.ArrayChar(64, "")
      ribbonSearchWidgetId = ribbonSearchWidgetId + 1
      lastRibbonFilterStr = ''
      selectedRibbonIdx = #ribbons
    end
    im.tooltip('Add a new ribbon (allows user to draw left/right edge node pairs with mouse).')
    im.SameLine()
    im.NextColumn()

    im.Dummy(iconsBig)
    im.SameLine()
    im.NextColumn()

    -- 'Remove All' button.
    if #ribbons > 0 then
      if editor.uiIconImageButton(icons.trashBin2, iconsBig, cols.blueB, nil, nil, 'removeAllRibbonsButton') then
        statePre = copyRibbonsState()
        for j = #ribbons, 1, -1 do
          audioRibbon.removeRibbon(j)
        end
        table.clear(ribbons)
        table.clear(ribbonNames)
        selectedRibbonIdx = 1
        updateUIBindings()
        editor.history:commitAction("RemoveAllribbons", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
        markRibbonUiDirty()
      end
      im.tooltip('Remove all ribbons from the list.')
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- 'Lock Shape' toggle button.
    if #ribbons > 0 then
      btnCol = isLockShape and cols.blueB or cols.blueD
      if editor.uiIconImageButton(icons.roadGuideArrowSolid, iconsBig, btnCol, nil, nil, 'lockShapeButton') then
        isLockShape = not isLockShape
      end
      im.tooltip((isLockShape and 'Unlock the shape of the ribbon (to move nodes separately)' or 'Lock the shape of the ribbon (to move nodes rigidly)'))
    else
      im.Dummy(iconsBig)
    end
    im.SameLine()
    im.NextColumn()

    -- Toggle gizmo on/off button.
    if #ribbons > 0 then
      btnCol, btnIcon = cols.blueD, icons.gizmosOutline
      if isGizmoActive then
        btnCol, btnIcon = cols.blueB, icons.gizmosSolid
      end
      if editor.uiIconImageButton(btnIcon, iconsBig, btnCol, nil, nil, 'toggleGizmoOnOffBtn') then
        isGizmoActive = not isGizmoActive
      end
      im.tooltip('Switch the translational gizmo ' .. (isGizmoActive and 'off' or 'on') .. ' (can also press ALT to toggle).')
    else
      im.Dummy(iconsBig)
    end
    im.NextColumn()
    im.Columns(1)
    im.Separator()

    if #ribbons < 1 then
      -- No ribbons.
    else
      -- Ribbons List Box.
      wasRibbonUiDirty = isRibbonUiDirty
      if wasRibbonUiDirty then
        rebuildRibbonUiOrder(ribbons)
      end
      filterStr = string.lower(ffi.string(ribbonSearchBuf))
      if filterStr ~= lastRibbonFilterStr or wasRibbonUiDirty then
        rebuildRibbonUiFiltered(ribbons, filterStr)
        lastRibbonFilterStr = filterStr
      end

      im.TextColored(cols.greenB, 'Search:')
      im.SameLine()
      im.PushItemWidth(-1)
      im.InputText("###ribbonSearch" .. tostring(ribbonSearchWidgetId), ribbonSearchBuf, 64)
      im.tooltip("Type to filter ribbons by name.")
      im.PopItemWidth()
      im.Separator()

      if im.BeginListBox('', im.ImVec2(-1, 180)) then
        hoveredRibbonIdx = nil
        im.Columns(4, "ribbonListBoxColumns", false)
        im.SetColumnWidth(0, 30)
        im.SetColumnWidth(1, 180)
        im.SetColumnWidth(2, 35)
        im.SetColumnWidth(3, 35)
        im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
        im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
        uiList = ribbonUiOrder
        if filterStr ~= '' then
          uiList = ribbonUiFiltered
        end
        if #uiList < 1 then
          im.Text('')
          im.NextColumn()
          im.Text('<No search matches>')
          im.NextColumn()
          im.Dummy(iconsSmall)
          im.NextColumn()
          im.Dummy(iconsSmall)
          im.NextColumn()
        end
        for uiIdx = 1, #uiList do
          -- Handle the individual row selection.
          ribbonIdx = uiList[uiIdx]
          ribbon = ribbons[ribbonIdx]
          if im.Selectable1('###' .. tostring(ribbonIdx), ribbonIdx == selectedRibbonIdx, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
            if ribbonIdx ~= selectedRibbonIdx then
              selectedRibbonIdx = ribbonIdx
              selectedNodeIdx = 1
              if ribbon and #ribbon.depths > 0 then
                masterSpeed = im.FloatPtr(ribbon.speed)
                masterDepth = ribbon.depths[1]
                ambientEventBinding = im.ArrayChar(128, ribbon.emitters[1].eventNameStr)
                frontEventBinding = im.ArrayChar(128, ribbon.emitters[2].eventNameStr)
                rearEventBinding = im.ArrayChar(128, ribbon.emitters[3].eventNameStr)
                rightEventBinding = im.ArrayChar(128, ribbon.emitters[4].eventNameStr)
                leftEventBinding = im.ArrayChar(128, ribbon.emitters[5].eventNameStr)
              end
            end
          end
          if im.IsItemHovered() then
            hoveredRibbonIdx = ribbonIdx
          end
          im.SameLine()
          im.NextColumn()

          -- Ribbon name field.
          im.PushItemWidth(-1)
          nameBinding = im.ArrayChar(128, ribbon.name)
          if ribbon.isEnabled then
            im.InputText("###100" .. tostring(ribbonIdx), nameBinding, 128)
            newName = ffi.string(nameBinding)
            if ribbon.name ~= newName then
              ribbon.name = newName
            end
            im.tooltip('Edit the name of this ribbon.')
            if im.IsItemActive() then
              selectedRibbonIdx = ribbonIdx
            end
            if im.IsItemDeactivatedAfterEdit() then
              markRibbonUiDirty()
            end
          else
            im.TextColored(cols.dullWhite, ribbon.name)
            im.tooltip('This ribbon is disabled. To edit or remove it, first enable it.')
          end
          if im.IsItemHovered() then
            hoveredRibbonIdx = ribbonIdx
          end
          im.NextColumn()
          im.PopItemWidth()

          -- 'Remove ribbon' button.
          if ribbon.isEnabled then
            if editor.uiIconImageButton(icons.trashBin2, iconsSmall, cols.blueB, nil, nil, 'removeRibbonButton' .. tostring(ribbonIdx)) then
              statePre = copyRibbonsState()
              audioRibbon.removeRibbon(ribbonIdx)
              selectedRibbonIdx = max(1, min(selectedRibbonIdx, #ribbons))
              updateUIBindings()
              editor.history:commitAction("Remove Ribbon", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
              markRibbonUiDirty()
              editor.endWindow()
              return
            end
            im.tooltip('Remove this ribbon from the list.')
          else
            im.Dummy(iconsSmall)
          end
          if im.IsItemHovered() then
            hoveredRibbonIdx = ribbonIdx
          end
          im.SameLine()
          im.NextColumn()

          -- 'Enable/Disable ribbon' button.
          local btnCol, btnIcon = cols.blueD, icons.lock
          if ribbon.isEnabled then btnCol, btnIcon = cols.blueB, icons.lock_open end
          if editor.uiIconImageButton(btnIcon, iconsSmall, btnCol, nil, nil, 'enableDisableRibbonButton' .. tostring(ribbonIdx)) then
            statePre = copyRibbonsState()
            audioRibbon.clearAllSFXEmitters()
            ribbon.isEnabled = not ribbon.isEnabled
            selectedRibbonIdx = ribbonIdx
            editor.history:commitAction(ribbon.isEnabled and "Enable Ribbon" or "Disable Ribbon", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
          end
          im.tooltip(ribbon.isEnabled and 'Disable this ribbon (will not emit audio).' or 'Enable this ribbon.')
          if im.IsItemHovered() then
            hoveredRibbonIdx = ribbonIdx
          end
          im.NextColumn()

          im.Separator()
        end
        im.PopStyleVar(2)
        im.EndListBox()
      end
      im.Separator()
      im.Columns(1)

      -- Continue only if the selected ribbon is valid and enabled.
      selRibbon = ribbons[selectedRibbonIdx]
      if not selRibbon or not selRibbon.isEnabled then
        editor.endWindow()
        return
      end

      -- The row of buttons under the list box.
      im.Columns(6, "btnsUnderListBoxRowColumns", false)
      im.SetColumnWidth(0, 40)
      im.SetColumnWidth(1, 40)
      im.SetColumnWidth(2, 40)
      im.SetColumnWidth(3, 40)
      im.SetColumnWidth(4, 40)
      im.SetColumnWidth(5, 40)

      -- 'Go To ribbon' button.
      selNodes = selRibbon.nodes
      if selNodes and #selNodes > 2 then
        if editor.uiIconImageButton(icons.cameraFocusTopDown, iconsBig, cols.blueB, nil, nil, 'goToSelectedRibbon') then
          util.goToSpline(selNodes)
        end
        im.tooltip('Go to this ribbon.')
      else
        im.Dummy(iconsSmall)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Conform To Surface Below' button.
      if editor.uiIconImageButton(icons.lineToTerrain, iconsBig, cols.blueB, nil, nil, 'conform2TerrainButton') then
        statePre = copyRibbonsState()
        conformRibbonToTerrain()
        editor.history:commitAction("Conform To Surface Below", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
      end
      im.tooltip('Conform the ribbon to the surface below.')
      im.SameLine()
      im.NextColumn()

      -- 'Quad/Single' toggle button.
      local btnIcon = icons.fg_math_symbol_plus
      if selRibbon.isAmbient then btnIcon = icons.simobject_sfxemitter end
      if editor.uiIconImageButton(btnIcon, iconsBig, cols.blueB, nil, nil, 'ambientRibbonToggleButton') then
        statePre = copyRibbonsState()
        audioRibbon.clearAllSFXEmitters()
        selRibbon.isAmbient = not selRibbon.isAmbient
        editor.history:commitAction(selRibbon.isAmbient and "Use Ambient" or "Use SFX", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
      end
      im.tooltip(selRibbon.isAmbient and 'Use 4 emitters on a (+) grid.' or 'Use single emitter (for ambient sources).')
      im.SameLine()
      im.NextColumn()

      -- 'Up Ribbon/Down Ribbon' toggle button.
      local btnIcon = icons.arrow_downward
      if not selRibbon.isUpRibbon then btnIcon = icons.arrow_upward end
      if editor.uiIconImageButton(btnIcon, iconsBig, cols.blueB, nil, nil, 'upDownRibbonToggleButton') then
        statePre = copyRibbonsState()
        selRibbon.isUpRibbon = not selRibbon.isUpRibbon
        editor.history:commitAction("Toggle Ribbon Up/Down", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
      end
      im.tooltip(selRibbon.isUpRibbon and 'Make ribbon point upwards.' or 'Make ribbon point downwards.')
      im.SameLine()
      im.NextColumn()

      -- 'Use Top/Bottom Surface' toggle button (for quad emitters only).
      if not selRibbon.isAmbient then
        local btnIcon = icons.vertical_align_bottom
        if not selRibbon.isTopActive then btnIcon = icons.vertical_align_top end
        if editor.uiIconImageButton(btnIcon, iconsBig, cols.blueB, nil, nil, 'useTopBottomActiveSurfaceToggleButton') then
          statePre = copyRibbonsState()
          selRibbon.isTopActive = not selRibbon.isTopActive
          editor.history:commitAction(selRibbon.isTopActive and "Use Top Surface" or "Use Bottom Surface", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
        end
        im.tooltip(selRibbon.isTopActive and 'Use the bottom face of the ribbon as the active surface.' or 'Use the top face of the ribbon as the active surface.')
      else
        im.Dummy(iconsBig)
      end
      im.SameLine()
      im.NextColumn()

      -- 'Use Volume For Quad Type' toggle button (for quad emitters only).
      if not selRibbon.isAmbient then
        local btnIcon = icons.crop_square
        if selRibbon.isQuadAndVolume then btnIcon = icons.polygonalCube end
        if editor.uiIconImageButton(btnIcon, iconsBig, cols.blueB, nil, nil, 'useVolumeForQuadTypeToggleButton') then
          local statePre = copyRibbonsState()
          selRibbon.isQuadAndVolume = not selRibbon.isQuadAndVolume
          editor.history:commitAction(selRibbon.isQuadAndVolume and "Use Volume For Quad Type" or "Use 2D Surfaces For Quad Type", { old = statePre, new = copyRibbonsState() }, editStateUndo, editStateRedo)
        end
        im.tooltip(selRibbon.isQuadAndVolume and 'Use a 2D surface (top or bottom).' or 'Use a 3D volume (the ribbon volume).')
      else
        im.Dummy(iconsBig)
      end
      im.NextColumn()
      im.Separator()
      im.Columns(1)

      -- Selected Emitter Details.
      renderSelectedEmitterDetails(icons, selRibbon)
    end
  end

  editor.endWindow()
end

-- World editor main callback for rendering the UI.
local function onEditorGui()
  if not isAudioRibbonEditor then
    return
  end
  local ribbons = audioRibbon.getRibbons()
  if not ribbons then
    onInit()
  end
  if isFirstTime then
    updateUIBindings()
    isFirstTime = false
  end

  -- Render the tool window UI first so ImGui hover/capture state is up to date for this frame.
  renderToolWindow()

  -- Render the ribbons on the map.
  render.renderRibbon(ribbons, selectedRibbonIdx, selectedNodeIdx, placedLeftNode, hoveredRibbonIdx, bestCursorSeg, isDragging)

  -- Handle user editing of the selected ribbon.
  out.ribbonIdx, out.nodeIdx, out.isGizmoActive = selectedRibbonIdx, selectedNodeIdx, isGizmoActive
  bestCursorSeg, isDragging = input.handleRibbonEvents(ribbons, out, true, isLockShape, masterDepth, audioRibbon.updateRibbonData, copyRibbonsState, editStateUndo, editStateRedo)
  selectedRibbonIdx, selectedNodeIdx, isGizmoActive = out.ribbonIdx, out.nodeIdx, out.isGizmoActive
end

-- Called when the tool icon is pressed.
local function onActivate()
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isAudioRibbonEditor = true
end

-- Called when the tool is exited.
local function onDeactivate()
  editor.hideWindow(toolWinName)
  isAudioRibbonEditor = false
end

-- Called upon world editor initialization.
local function onEditorInitialized()
  editor.editModes.audioRibbonEditMode = {
    displayName = "Audio Ribbon Editor",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.simobject_sfxspace,
    iconTooltip = "Audio Ribbon Editor",
    auxShortcuts = {},
    hideObjectIcons = true }
  editor.registerWindow(toolWinName, toolWinSize)
end


-- Public interface.
M.onInit =                                                onInit

M.onEditorGui =                                           onEditorGui
M.onEditorInitialized =                                   onEditorInitialized

return M
