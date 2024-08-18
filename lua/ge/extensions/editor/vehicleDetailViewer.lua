-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- F11 > Window > Experimental > Vehicle detail viewer

local M = {}

local im = ui_imgui
local imUtils = require('ui/imguiUtils')

local colRed = ColorF(1,0,0,1)
local colMagenta = ColorF(1,0,1,1)

local sizeX = 512 * 16/10
local sizeY = 512

local views

local dragView = nil

local timer = 0

local meterToPixelScale = 200


local statusMessage

local resolutionMultiplier = im.IntPtr(3)

local saveFolder = '/settings/vehicleDetails/'
local layoutFilenameDefault = saveFolder .. 'default.vehicleDetailSetting.json'
local saveFilenameFFI = im.ArrayChar(128, "default")
local availableLayoutFiles = {}
local loadedLayoutBaseFilename = 'default'

local toolWindowName = 'Vehicle Detail Viewer'

local function drawBoundinBox(veh)
  local bb = veh:getSpawnWorldOOBB()
  local c = bb:getCenter()
  local ex = bb:getHalfExtents().x
  local ey = bb:getHalfExtents().y
  local ez = bb:getHalfExtents().z
  local ax0 = bb:getAxis(0)
  local ax1 = bb:getAxis(1)
  local ax2 = bb:getAxis(2)
  -- Points
  --[[
     5----------6
    /|         /|
   / |        / |
  1----------2  |
  |  |       |  |
  |  8-------|--7
  | /        | /
  |/         |/
  4----------3
  ]]
  local p1 = c + ax0 * ex + ax1 * ey + ax2 * ez
  local p2 = c + ax0 * ex + ax1 * ey - ax2 * ez
  local p3 = c + ax0 * ex - ax1 * ey + ax2 * ez
  local p4 = c + ax0 * ex - ax1 * ey - ax2 * ez
  local p5 = c - ax0 * ex + ax1 * ey + ax2 * ez
  local p6 = c - ax0 * ex + ax1 * ey - ax2 * ez
  local p7 = c - ax0 * ex - ax1 * ey + ax2 * ez
  local p8 = c - ax0 * ex - ax1 * ey - ax2 * ez

  -- Draw lines for the bounding box
  debugDrawer:drawLine(p1, p2, colRed)
  debugDrawer:drawLine(p2, p4, colRed)
  debugDrawer:drawLine(p4, p3, colRed)
  debugDrawer:drawLine(p3, p1, colRed)
  debugDrawer:drawLine(p5, p6, colRed)
  debugDrawer:drawLine(p6, p8, colRed)
  debugDrawer:drawLine(p8, p7, colRed)
  debugDrawer:drawLine(p7, p5, colRed)
  debugDrawer:drawLine(p1, p5, colRed)
  debugDrawer:drawLine(p2, p6, colRed)
  debugDrawer:drawLine(p3, p7, colRed)
  debugDrawer:drawLine(p4, p8, colRed)
  debugDrawer:drawSphere(c, 0.1, colRed)
end

local function sign3(number)
  return number >= 0 and 1 or -1
end

local function renderOrthoView(veh, view)
  local axisIdx = math.abs(view.axis)
  local axisSign = sign3(view.axis)

  -- Get the bounding box details
  local bb = veh:getSpawnWorldOOBB()
  local c = bb:getCenter()
  local e = bb:getHalfExtents()
  local eNorm = e:normalized()
  local ax = { bb:getAxis(0), bb:getAxis(1), bb:getAxis(2) }

  local scale = view.zoom -- 1.1 for 10% border

  local offsetX = view.dragOffset and view.dragOffset.x or 0
  local offsetY = view.dragOffset and view.dragOffset.y or 0

  local sizeX = view.size.x / meterToPixelScale
  local sizeY = view.size.y / meterToPixelScale

  local left     = -sizeX * scale + offsetX
  local right    =  sizeX * scale + offsetX
  local top      =  sizeY * scale + offsetY
  local bottom   = -sizeY * scale + offsetY

  -- the fit versions will be a perfect fit for the vehicle present
  local configs = {
    { -- left/right
      leftFit   = -e.y * sizeX * scale + offsetX,
      rightFit  =  e.y * sizeX * scale + offsetX,
      topFit    =  e.z * sizeY * scale + offsetY,
      bottomFit = -e.z * sizeY * scale + offsetY,
      camPos    = c - ax[1] * (2 * e.x * axisSign),
      camDir    = ax[1] * axisSign,
      camUp     = ax[3],
      camUpAxis = vec3(0,0,1),
    },
    { -- front/back
      leftFit   = -e.x * scale + offsetX,
      rightFit  =  e.x * scale + offsetX,
      topFit    =  e.z * scale + offsetY,
      bottomFit = -e.z * scale + offsetY,
      camPos    = c - ax[2] * (2 * e.y * axisSign),
      camDir    = ax[2] * axisSign,
      camUp     = ax[3],
      camUpAxis = vec3(0,0,1),
    },
    { -- top/bottom
      leftFit   = -e.x * scale + offsetX,
      rightFit  =  e.x * scale + offsetX,
      topFit    =  e.y * scale + offsetY,
      bottomFit = -e.y * scale + offsetY,
      camPos    = c - ax[3] * (2 * e.x * axisSign),
      camDir    = ax[3] * axisSign,
      camUp     = -ax[1],
      camUpAxis = vec3(-1,0,0),
    },
  }

  local config = configs[axisIdx]

  -- Increase the camera distance if the vehicle is large
  local cameraMatrix = MatrixF()

  cameraMatrix:createOrientFromDirUp(config.camDir, view.fixAxis and config.camUpAxis or config.camUp)
  cameraMatrix:setPosition(config.camPos)

  -- Set up the RenderView
  local rv = view.runtime and view.runtime.rv or nil
  if not rv then
    rv = RenderViewManagerInstance:getOrCreateView(view.name)
    if not view.runtime then view.runtime = {} end
    view.runtime.rv = rv
    rv.luaOwned = true -- make sure the view is deleted properly if the GC collects it
    rv.namedTexTargetColor = view.name
    rv.renderCubemap = false
    rv.renderEditorIcons = false
    rv.fov = math.rad(90)
    rv:enterFocusObjectsMode()
    rv:addFocusObject(veh)
    rv:maskSet(1)
  end

  local renderOrthogonal = true
  local aspectRatio = 2.3
  --local nearClip = 0.1 -- math.sin(timer) + 2.6
  local farClip = 10

  rv.resolution = Point2I(view.size.x * resolutionMultiplier[0], view.size.y * resolutionMultiplier[0])
  rv.viewPort = RectI(0, 0, view.size.x * resolutionMultiplier[0], view.size.y * resolutionMultiplier[0])
  rv.frustum = Frustum.constructOrtho(left, right, top, bottom, view.nearClip, farClip)

  rv.cameraMatrix = cameraMatrix

  if view.debug then
    debugDrawer:drawFrustum(cameraMatrix, rv.frustum, colMagenta)
  end
end

local function createViewsForVehicle(veh)
  views = {}
  -- Get the bounding box details
  local bb = veh:getSpawnWorldOOBB()
  local c = bb:getCenter()
  local e = bb:getHalfExtents()

  -- Calculate the dimensions of the bounding box in world space
  local bbWidth = e.x * 2 * meterToPixelScale
  local bbHeight = e.y * 2 * meterToPixelScale
  local bbDepth = e.z * 2 * meterToPixelScale

  local sizeIso = math.max(e.x, e.y, e.z) * 2 * meterToPixelScale

  table.insert(views, {name = 'Left',   size = {x = bbHeight, y = bbDepth},  axis = -1})
  table.insert(views, {name = 'Right',  size = {x = bbHeight, y = bbDepth},  axis =  1})
  table.insert(views, {name = 'Front',  size = {x = bbWidth,  y = bbDepth},  axis =  2})
  table.insert(views, {name = 'Back',   size = {x = bbWidth,  y = bbDepth},  axis = -2})
  table.insert(views, {name = 'Top',    size = {x = bbHeight,  y = bbWidth}, axis = -3})
  table.insert(views, {name = 'Bottom', size = {x = bbHeight,  y = bbWidth}, axis =  3})

  -- set some defaults
  for i, view in pairs(views) do
    view.zoom = 1
    view.nearClip = 0.1
    view.dragOffset = {x = 0, y = 0}
    view.windowOpen = im.BoolPtr(false)
  end
end

local function handleImageInput(view)
  if view.freeze then return end
  -- Handle mouse dragging
  if im.IsItemHovered() then
    local wheel = im.GetIO().MouseWheel
    local isShiftHeld = im.IsKeyDown(im.GetKeyIndex(im.Key_ModShift))
    local isCtrlHeld = im.IsKeyDown(im.GetKeyIndex(im.Key_ModCtrl))

    if wheel ~= 0 then
      if isShiftHeld then
        view.nearClip = math.max(-20, math.min(20, view.nearClip + wheel * 0.1))
        --dump{'near: ', view.nearClip}
      else
        view.zoom = math.max(0.01, math.min(3, view.zoom - wheel * (0.1 * math.min(1, view.zoom))))
        --dump{'zoom: ', view.zoom}
      end
    end

    if im.IsMouseDown(0) then
      if not view.isDragging then
        view.isDragging = true
        view._DragInitialMousePos = im.GetMousePos()
      else
        local currentMouse = im.GetMousePos()
        view.dragOffset.x = view.dragOffset.x - (currentMouse.x - view._DragInitialMousePos.x) / meterToPixelScale * 0.9 * view.zoom * 2
        view.dragOffset.y = view.dragOffset.y + (currentMouse.y - view._DragInitialMousePos.y) / meterToPixelScale * 0.9 * view.zoom * 2
        view._DragInitialMousePos = currentMouse
        im.SetMouseCursor(2) -- ResizeAll cursor
      end
    else
      view.isDragging = false
      view._DragInitialMousePos = nil
      im.SetMouseCursor(0) -- default
    end

    if im.IsMouseDoubleClicked(0) then
      view.dragOffset.x = 0
      view.dragOffset.y = 0
      view.zoom = 1
    end
  end
end

local function refreshLayoutFiles()
  availableLayoutFiles = FS:findFiles(saveFolder, '*.vehicleDetailSetting.json', -1, false, false) or {}
end

local function onSerialize()
  -- kill objects before serializing and convert pointers
  for _, view in pairs(views or {}) do
    if view and view.runtime and view.runtime.rv then
      RenderViewManagerInstance:destroyView(view.runtime.rv)
    end
    view.runtime = nil
    view.windowOpen = view.windowOpen and view.windowOpen[0] or false
    if view.windowPos then
      view.windowPos = {x = view.windowPos.x, y = view.windowPos.y}
    end
    if view.windowSize then
      view.windowSize = {x = view.windowSize.x, y = view.windowSize.y}
    end
    --view.windowViewport
  end
  return { views = views}
end

local function onDeserialized(data)
  if not data then return end
  views = data.views
  -- convert pointers back
  for _, view in pairs(views or {}) do
    view.windowOpen = im.BoolPtr(view.windowOpen or false)
  end
end

local function onPreRender(dtReal, dtSim, dtRaw)
  if not editor.beginWindow then return end -- for some frames, the editor is not ready yet

  local vehId = be:getPlayerVehicleID(0)
  local veh = be:getObjectByID(vehId)
  if not veh then return end

  timer = timer + dtReal

  debugDrawer.currentRenderViewMask = 0

  --debugDrawer:drawLine(vec3(0,0,0), vec3(0,0,10), colRed)

  --drawBoundinBox(veh)

  if not views then
    onDeserialized(jsonReadFile(layoutFilenameDefault))
    if not views then
      createViewsForVehicle(veh)
    end
  end

  --im.SetNextWindowSize(im.ImVec2(600,450), im.Cond_Appearing)
  if editor.beginWindow(toolWindowName, "Vehicle Detail Viewer##vehDetView") then
    local tableFlags = bit.bor(im.TableFlags_Resizable,im.TableFlags_RowBg,im.TableFlags_Borders)
    if im.BeginTable('##views', 6, tableFlags) then
      im.TableSetupScrollFreeze(0, 1) -- Make top row always visible
      im.TableSetupColumn("Name", nil, 5)
      im.TableSetupColumn("Zoom", nil, 5)
      im.TableSetupColumn("Offset", nil, 10)
      im.TableSetupColumn("nearClip", nil, 5)
      im.TableSetupColumn("resolution", nil, 5)
      im.TableSetupColumn("Controls", nil, 30)
      im.TableHeadersRow()

      for i, view in pairs(views) do
        im.TableNextColumn()
        im.TextUnformatted(tostring(view.name))
        im.TableNextColumn()
        im.TextUnformatted(tostring(roundNear(view.zoom, 100)))
        im.TableNextColumn()
        im.TextUnformatted(tostring(roundNear(view.dragOffset.x, 100)) .. ', ' .. tostring(roundNear(view.dragOffset.y, 100)))
        im.TableNextColumn()
        im.TextUnformatted(tostring(roundNear(view.nearClip, 100)))
        im.TableNextColumn()
        im.TextUnformatted(tostring(math.floor(view.size.x)) .. 'x' .. tostring(math.floor(view.size.y)))
        im.TableNextColumn()

        if not view.windowOpen[0] then
          if im.SmallButton('open##'..tostring(view.name)) then
            view.windowOpen[0] = true
          end
        else
          if im.SmallButton('close##'..tostring(view.name)) then
            view.windowOpen[0] = false
          end
        end
        if i > 6 then
          im.SameLine()
          if im.SmallButton('delete##'..tostring(view.name)) then
            views[i] = nil
          end
        end
        im.SameLine()
        if im.SmallButton('clone##'..tostring(view.name)) then
          table.insert(views, {
            name = view.name .. ' ' .. tostring(#views),
            size = {x = view.size.x, y = view.size.y},
            axis = view.axis,
            zoom = view.zoom,
            nearClip = view.nearClip,
            dragOffset = {x = view.dragOffset.x, y = view.dragOffset.y},
            windowOpen = im.BoolPtr(view.windowOpen[0])
          })
        end
        if view.runtime and view.runtime.rv then
          im.SameLine()
          if im.SmallButton('PNG##save'..tostring(view.name)) then
            local filename = view.name .. '-' .. tostring(loadedLayoutBaseFilename) .. '.png'
            view.runtime.rv:saveToDisk(filename)
            log('I', 'thumbnail', 'saved to disk: ' .. tostring(filename))
            statusMessage = 'image saved: ' .. tostring(filename)
          end
        end
        if view.windowOpen[0] then
          im.SameLine()
          if view.debug == true then
            if im.SmallButton('no debug##nodebug'..tostring(view.name)) then
              view.debug = nil
            end
          else
            if im.SmallButton('debug##debug'..tostring(view.name)) then
              view.debug = true
            end
          end
          im.SameLine()
          if view.fixAxis == nil then
            if im.SmallButton('fix Axis##fixAxis'..tostring(view.name)) then
              view.fixAxis = true
            end
          else
            if im.SmallButton('unfix Axis##unfixAxis'..tostring(view.name)) then
              view.fixAxis = nil
            end
          end
          im.SameLine()
          if view.freeze == nil then
            if im.SmallButton('freeze##freeze'..tostring(view.name)) then
              view.freeze = true
            end
          else
            if im.SmallButton('unfreeze##unfreeze'..tostring(view.name)) then
              view.freeze = nil
            end
          end
        end

        im.TableNextRow()
      end
      im.EndTable()

      if statusMessage then
        im.PushStyleColor2(im.Col_Text, im.ImVec4(0, 1, 0, 1))
        im.TextUnformatted(statusMessage)
        if im.IsItemClicked(0) then
          statusMessage = nil
        end
        im.PopStyleColor()
      end

      if im.CollapsingHeader1("Layouts###Layouts") then
        if im.SmallButton('reset current##resetLayouy') then
          createViewsForVehicle(veh)
        end
        im.Separator()

        im.TextUnformatted("Save Layout")
        im.SameLine()
        im.SetCursorPosX(200)
        im.SetNextItemWidth(200)
        im.InputText("##saveLayoutfilename", saveFilenameFFI)
        im.SameLine()

        if im.SmallButton('save##saveLayouy') then
          local baseFilename = ffi.string(saveFilenameFFI)
          local layoutFilename = saveFolder .. baseFilename  .. '.vehicleDetailSetting.json'
          jsonWriteFile(layoutFilename, onSerialize())
          onDeserialized(jsonReadFile(layoutFilename))
          loadedLayoutBaseFilename = baseFilename
          statusMessage = 'Layout saved: ' .. layoutFilename
          refreshLayoutFiles()
        end
        im.Separator()
        if #availableLayoutFiles > 0 then
          im.TextUnformatted("Available Layouts:")
          for lidx, layoutFilename in ipairs(availableLayoutFiles) do
            local _, baseFilename = path.splitWithoutExt(layoutFilename, '.vehicleDetailSetting.json')
            if loadedLayoutBaseFilename == baseFilename then
              im.PushStyleColor2(im.Col_Text, im.ImVec4(0, 1, 0, 1))
              im.TextUnformatted(baseFilename)
              im.PopStyleColor()
            else
              im.TextUnformatted(baseFilename)
            end
            im.SameLine()
            im.SetCursorPosX(200)
            if im.SmallButton('load##loadLayouy_'..tostring(lidx)) then
              loadedLayoutBaseFilename = baseFilename
              onDeserialized(jsonReadFile(layoutFilename))
              statusMessage = 'Layout loaded: ' .. layoutFilename
            end
            im.SameLine()
            if im.SmallButton('overwrite##overwriteLayouy_'..tostring(lidx)) then
              jsonWriteFile(layoutFilename, onSerialize())
              onDeserialized(jsonReadFile(layoutFilename))
              statusMessage = 'Layout saved: ' .. layoutFilename
              refreshLayoutFiles()
            end
            im.SameLine()
            if im.SmallButton('delete##deleteLayouy_'..tostring(lidx)) then
              FS:removeFile(layoutFilename)
              statusMessage = 'Layout deleted: ' .. layoutFilename
              refreshLayoutFiles()
            end
          end
        end
      end

      --  float_v_speed, int_v_min, int_v_max, string_format, ImGuiSliderFlags_flags
      if im.CollapsingHeader1("Options##Options") then
        im.TextUnformatted('Image saving resolution multiplier: ')
        im.SameLine()
        im.SetNextItemWidth(100)
        if im.InputInt("##ResolutionMultiplier", resolutionMultiplier, 1) then
          if resolutionMultiplier[0] < 1 then
            resolutionMultiplier[0] = 1
          elseif resolutionMultiplier[0] > 3 then
            resolutionMultiplier[0] = 3
          end
        end
      end

      if im.CollapsingHeader1("Controls###Controls") then
        im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 1, 1, 0.8))
        im.TextUnformatted('click+drag = move')
        im.TextUnformatted('mousewheel = zoom')
        im.TextUnformatted('shift + mousewheel = nearclip')
        im.TextUnformatted('doubleclick = reset')
        im.PopStyleColor()
        im.EndChild()
      end

      if settings.getValue("vsync") then
        im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 0, 0, 1))
        im.TextUnformatted('!!! DISABLE VSYNC !!')
        im.PopStyleColor()
      end

    end
    editor.endWindow()
  end

  im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(0, 0))

  for i, view in pairs(views or {}) do
    if view.windowOpen[0] then
      local txt = ''
      if view.freeze then
        txt = txt .. ' [FROZEN]'
      end
      -- GetWindowDockID
      --im.SetNextWindowDockID(self.fgEditor.dockspaces["NE_Main_Dockspace"])
      im.SetNextWindowSize(im.ImVec2(view.size.x, view.size.y), im.Cond_Appearing)
      im.PushID1('CDV_' .. loadedLayoutBaseFilename .. '_' .. view.name)
      if im.Begin('Vehicle Detail View - ' .. view.name .. ' - ' .. loadedLayoutBaseFilename .. txt, view.windowOpen) then
        if not view.freeze then
          view.size.x = im.GetContentRegionAvail().x
          view.size.y = im.GetContentRegionAvail().y
          renderOrthoView(veh, view)
        end
        local texObj = imUtils.texObj('#' .. view.name)
        im.Image(texObj.texId, im.ImVec2(view.size.x, view.size.y))
        handleImageInput(view)
        im.End()
        view.dockID = im.GetWindowDockID()
        view.docked = im.IsWindowDocked()
        view.windowPos = im.GetWindowPos()
        view.windowSize = im.GetWindowSize()
        view.windowViewport = im.GetWindowViewport()
      end
    else
      -- clean up any remaining things
      if view.runtime and view.runtime.rv then
        RenderViewManagerInstance:destroyView(view.runtime.rv)
        view.runtime.rv = nil
      end
    end
  end

  im.PopStyleVar()

  debugDrawer.currentRenderViewMask = 0

  if not editor.isWindowVisible(toolWindowName) then
    -- do not render anything
    for _, view in pairs(views or {}) do
      if view and view.runtime and view.runtime.rv then
        RenderViewManagerInstance:destroyView(view.runtime.rv)
        view.windowOpen[0] = false
      end
      view.runtime = nil
    end
  end
end

local function onVehicleSpawned(vehicleId)
  -- recreate the views
  views = nil
end

local function onExtensionLoaded()
  print('editor_vehicleDetailViewer loaded')
  refreshLayoutFiles()
end

local function onExtensionUnloaded()
  for _, view in pairs(views or {}) do
    if view and view.runtime and view.runtime.rv then
      RenderViewManagerInstance:destroyView(view.runtime.rv)
    end
  end
  print('editor_vehicleDetailViewer unloaded')
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, im.ImVec2(600,550))
  editor.addWindowMenuItem(toolWindowName, function() editor.showWindow(toolWindowName) end, {groupMenuName = 'Experimental'})
end

M.onEditorInitialized = onEditorInitialized

M.onDeserialized = onDeserialized
M.onSerialize = onSerialize

M.onPreRender = onPreRender
M.onVehicleSpawned = onVehicleSpawned

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M