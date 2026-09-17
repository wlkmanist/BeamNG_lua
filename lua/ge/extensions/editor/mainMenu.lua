-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local logTag = 'editor_main_menu'
M.dependencies = {"editor_layoutManager"}
local ffi = require('ffi')
local imgui = ui_imgui
local imgui_true = imgui.BoolTrue()
local imgui_false = imgui.BoolFalse()
local drawGizmoPlane = imgui.BoolPtr(true)
local smoothCameraMove = imgui.BoolPtr(false)
local smoothCameraRotate = imgui.BoolPtr(false)
local opened = imgui.BoolPtr(true)
local displaySceneMetric = imgui.BoolPtr(true)
local showCompleteSceneTree = imgui.BoolPtr(false)
local showNavGraphDrivability = imgui.BoolPtr(false)

local defaultWindowMenuItems = {}
local defaultWindowMenuGroups = {}
local windowMenuItems = {}
local windowMenuGroups = {}
local recentWindowMenuKeys = {}

local function getRecentWindowMenuLimit()
  -- preference lives in Preferences -> General -> General
  -- user-facing location: Preferences -> General -> User Interface (ui.general)
  local limit = editor and editor.getPreference and editor.getPreference("ui.general.recentWindowMenuCount") or 5
  if type(limit) ~= "number" then limit = 5 end
  limit = math.floor(limit)
  if limit < 0 then limit = 0 end
  return limit
end

local function makeWindowMenuKey(item)
  if not item then return nil end
  if item.menuGroupName and item.menuGroupName ~= "" then
    return tostring(item.menuGroupName) .. " > " .. tostring(item.itemText)
  end
  return tostring(item.itemText)
end

local function trimRecentWindowMenuKeys()
  local limit = getRecentWindowMenuLimit()
  if limit <= 0 then
    table.clear(recentWindowMenuKeys)
    return
  end
  while #recentWindowMenuKeys > limit do
    table.remove(recentWindowMenuKeys)
  end
end

local function findWindowMenuItemByKey(key)
  if not key or key == "" then return nil end
  local scan = function(menuGroups, menuItems)
    for _, item in ipairs(menuItems) do
      if item.isGroup then
        local groupName = item.itemText
        for _, subitem in ipairs(menuGroups[groupName] or {}) do
          if makeWindowMenuKey(subitem) == key then return subitem end
        end
      else
        if makeWindowMenuKey(item) == key then return item end
      end
    end
    return nil
  end

  -- try non-default tools first (most likely), then default section
  return scan(windowMenuGroups, windowMenuItems) or scan(defaultWindowMenuGroups, defaultWindowMenuItems)
end

local function pruneRecentWindowMenuKeys()
  -- Remove any entries that no longer exist in the current Window menu,
  -- and dedupe while preserving the MRU order.
  local seen = {}
  for i = #recentWindowMenuKeys, 1, -1 do
    local key = recentWindowMenuKeys[i]
    if type(key) ~= "string" or key == "" then
      table.remove(recentWindowMenuKeys, i)
    elseif seen[key] then
      table.remove(recentWindowMenuKeys, i)
    else
      local item = findWindowMenuItemByKey(key)
      if not item or not item.actionFunc then
        table.remove(recentWindowMenuKeys, i)
      else
        seen[key] = true
      end
    end
  end
  trimRecentWindowMenuKeys()
end

local function recordRecentWindowMenuItem(item)
  if not item or item.isDefaultToolWindow then return end -- avoid duplicating built-in default tools section
  local limit = getRecentWindowMenuLimit()
  if limit <= 0 then return end
  local key = makeWindowMenuKey(item)
  if not key or key == "" then return end

  for i = #recentWindowMenuKeys, 1, -1 do
    if recentWindowMenuKeys[i] == key then
      table.remove(recentWindowMenuKeys, i)
      break
    end
  end
  table.insert(recentWindowMenuKeys, 1, key)
  trimRecentWindowMenuKeys()
end

local metrics = {}
local metricsTim = 0
local systemMemoryInfo
local gpuMemoryInfo
local metricWarningColor = imgui.ImVec4(1, 1, 0.2, 1)
local metricCriticalColor = imgui.ImVec4(1, 0.3, 0.3, 1)
local bytesPerGiB = 1024 * 1024 * 1024

local bor = bit.bor
local notificationShowTime = 4 -- seconds, total time to show a notification
local notificationFadeTime = 1 -- seconds, time amount from total time when notification is fading
local forceShowNewest = true -- if true this will hide the current showing notification and show the newest one (valid for one liner title text notification)
local aboutDlgName = "aboutDlg"
local safeModeDlgName = "safeModeDlg"
local openSafeModePopup = false
local saveLayoutWindowName = "saveLayoutWindow"
local saveLayoutWindowTitle = "Save Layout"
local deleteLayoutWindowName = "deleteLayoutWindow"
local deleteLayoutWindowTitle = "Delete Layout"
local resetLayoutsWindowName = "resetLayoutsWindow"
local resetLayoutsWindowTitle = "Reset Layouts"
local revertLevelToOriginalWindowName = "revertLevelWindow"
local revertLevelToOriginalWindowTitle = "Revert Level to Original"
local showRevertLevelToOriginalButton = false
local fpsSmoother = newExponentialSmoothing(50, 1)
local windowSearch = require('/lua/ge/extensions/editor/util/searchUtil')()
local windowSearchTxt = imgui.ArrayChar(256, "")
local windowSearchDisplayResult = false
local windowSearchResults = {}

local function rebuildCollision(force)
  if force or Engine.getNeedCollisionRebuild() then
    log("I", "", "Rebuilding Static Collision Data...")
    be:reloadCollision()
    Engine.clearNeedCollisionRebuild()
    editor.showNotification("Rebuilt Static Collision Data")
  end
end

--- Add a new notification to the queue. It will override any notification in the same group (if present).
-- @param text the text of the notification
-- @param icon the icon (from editor.icons.*) to be shown next to the text (optional)
-- @param group the group name of this notification, it will override any current notification shown for this group (optional)
-- @param duration duration in seconds to show the notification, otherwise a default value will be used (optional)
-- @param doBeep make a beep sound for audio feedback
local function showNotification(text, icon, group, duration, doBeep)
  local notification = {
    time = 0,
    text = text,
    icon = icon or editor.icons.info,
    group = group or "",
    duration = duration or notificationShowTime,
    doBeep = doBeep
  }

  table.insert(editor.notificationQueue, notification)

  -- TODO: remove when notifications will be small floating windows
  if forceShowNewest then
    editor.currentNotificationIndex = tableSize(editor.notificationQueue)
  end

  --TODO: trim to maxNotificationCount
end

local function updateNotifications()
  -- if no index and no notifications, exit
  if editor.currentNotificationIndex == 0 and tableIsEmpty(editor.notificationQueue) then return end
  -- if all notifications were shown and the last one was also shown
  if editor.currentNotificationIndex == 0
    and (not tableIsEmpty(editor.notificationQueue))
    and editor.notificationQueue[tableSize(editor.notificationQueue)].time > editor.notificationQueue[tableSize(editor.notificationQueue)].duration then return end

  if editor.currentNotificationIndex == 0 then editor.currentNotificationIndex = tableSize(editor.notificationQueue) end

  local notification = editor.notificationQueue[editor.currentNotificationIndex]

  if notification.time > notification.duration then
    editor.currentNotificationIndex = editor.currentNotificationIndex + 1
    if editor.currentNotificationIndex > tableSize(editor.notificationQueue) then editor.currentNotificationIndex = 0 return end
  end

  notification.time = notification.time + editor.getDeltaTime()
end

local function fileMenu()
  if imgui.BeginMenu(_tr("editor.menu.file"), imgui_true) then
    if imgui.MenuItem1(_tr("editor.menu.newLevel"), "Ctrl+N", imgui_false, imgui_true) then
      editor.doNewLevel()
    end
    if imgui.MenuItem1(_tr("editor.menu.openLevel"), "Ctrl+O", imgui_false, imgui_true) then
      editor.doOpenLevel()
    end
    imgui.Separator()
    if imgui.MenuItem1(_tr("editor.menu.saveLevel"), "Ctrl+S", imgui_false, imgui_true) then
      editor.doSaveLevel()
    end
    --TODO: Save As disabled because issues with replacing old level paths to new copied level path/name
    -- in all of the assets json. Will be added after a proper asset system is in place
    -- if imgui.MenuItem1("Save Level As...", "Ctrl+Shift+S", imgui_false, imgui_true) then
    --   editor.doSaveLevelAs()
    -- end
    if editor.getLevelPath() ~= "" and showRevertLevelToOriginalButton then
      if imgui.MenuItem1("Delete This Level's User Folder Files", "", imgui_false, imgui_true) then
        editor.showWindow(revertLevelToOriginalWindowName)
      end
      imgui.tooltip("Will delete all the current level's files found in the user folder (doesn't affect official files)")
    end
    imgui.Separator()
    if imgui.MenuItem1(_tr("editor.menu.exportToCollada"), "", imgui_false, imgui_true) then
      editor_fileDialog.saveFile(
        function(data)
          worldEditorCppApi.colladaExportSelection(data.filepath)
        end,
        {{"Collada file",".dae"}},
        false,
        "/",
        "File already exists.\nDo you want to overwrite the file?"
      )
    end
    if imgui.MenuItem1(_tr("editor.menu.exit"), "F11", imgui_false, imgui_true) then
      editor.toggleActive()
    end
    imgui.EndMenu()
  end
end

local function editMenu()
  if imgui.BeginMenu(_tr("editor.menu.edit"), imgui_true) then
    if imgui.MenuItem1(_tr("editor.menu.undo"), "Ctrl+Z", imgui_false, imgui_true) then
      editor.undo()
    end
    if imgui.MenuItem1(_tr("editor.menu.redo"), "Ctrl+Y", imgui_false, imgui_true) then
      editor.redo()
    end
    imgui.Separator()
    if imgui.MenuItem1(_tr("editor.menu.cut"), "Ctrl+X", imgui_false, imgui_true) then
      editor.cut()
    end
    if imgui.MenuItem1(_tr("editor.menu.copy"), "Ctrl+C", imgui_false, imgui_true) then
      editor.copy()
    end
    if imgui.MenuItem1(_tr("editor.menu.paste"), "Ctrl+V", imgui_false, imgui_true) then
      editor.paste()
    end
    if imgui.MenuItem1(_tr("editor.menu.duplicate"), "Ctrl+D", imgui_false, imgui_true) then
      editor.duplicate()
    end
    imgui.Separator()
    if imgui.MenuItem1(_tr("editor.menu.selectAll"), "Ctrl+A", imgui_false, imgui_true) then
      editor.selectAll()
    end
    if imgui.MenuItem1(_tr("editor.menu.deselect"), "X", imgui_false, imgui_true) then
      editor.deselect()
    end
    if imgui.MenuItem1(_tr("editor.menu.delete"), "Delete", imgui_false, imgui_true) then
      editor.deleteSelection()
    end
    imgui.Separator()
    if imgui.MenuItem1(_tr("editor.menu.rebuildCollision"), "Ctrl+F7") then
      -- we force the rebuild
      editor.rebuildCollision(true)
    end
    if imgui.MenuItem1(_tr("editor.menu.reloadNavgraph")) then
      if map then
        log("I", "", "Reloading Navgraph Data...")
        map.reset()
      end
    end
    if imgui.MenuItem1(_tr("editor.menu.toggleMuteGameAudio"), nil, imgui_false, imgui_true) then
      editor.muteAudio(not editor.muted)
    end
    imgui.Separator()
    if imgui.MenuItem1(_tr("editor.menu.preferences"), nil, imgui_false, imgui_true) then
      editor.showPreferences()
    end
    imgui.EndMenu()
  end
end

local function cameraMenu()
  if imgui.BeginMenu(_tr("editor.menu.camera"), imgui_true) then
    if imgui.MenuItem1("Game Camera", "Ctrl+1", imgui_false, imgui_true) then
      editor.selectCamera(editor.CameraType_Game)
    end
    if imgui.MenuItem1(_tr("editor.menu.freeCamera"), "Ctrl+2", imgui_false, imgui_true) then
      editor.selectCamera(editor.CameraType_Free)
    end
    if imgui.MenuItem1(_tr("editor.menu.toggleFreeCamera"), "Shift+C", imgui_false, imgui_true) then
      editor.toggleFreeCamera()
    end
    if imgui.MenuItem1(_tr("editor.menu.placeCameraAtSelection"), "Ctrl+Q", imgui_false, imgui_true) then
      editor.placeCameraAtSelection()
    end
    if imgui.MenuItem1(_tr("editor.menu.placeCameraAtPlayer"), "Alt+Q", imgui_false, imgui_true) then
      editor.placeCameraAtPlayer()
    end
    if imgui.MenuItem1(_tr("editor.menu.placePlayerAtCamera"), "Alt+W", imgui_false, imgui_true) then
      editor.placePlayerAtCamera()
    end
    if imgui.MenuItem1(_tr("editor.menu.fitViewToSelection"), "F", imgui_false, imgui_true) then
      editor.fitViewToSelectionSmooth()
    end
    imgui.Separator()
    smoothCameraMove[0] = editor.getPreference("camera.general.smoothCameraMove")
    if imgui.Checkbox(_tr("editor.menu.smoothCameraMovement"), smoothCameraMove) then
      editor.setPreference("camera.general.smoothCameraMove", smoothCameraMove[0])
    end
    smoothCameraRotate[0] = editor.getPreference("camera.general.smoothCameraRotate")
    if imgui.Checkbox(_tr("editor.menu.smoothCameraRotation"), smoothCameraRotate) then
      editor.setPreference("camera.general.smoothCameraRotate", smoothCameraRotate[0])
    end
    imgui.EndMenu()
  end
end

local function objectMenu()
  if imgui.BeginMenu(_tr("editor.menu.object"), imgui_true) then
    if imgui.MenuItem1(_tr("editor.menu.lockSelection"), "Ctrl+Alt+L", imgui_false, imgui_true) then
      editor.lockObjectSelection()
    end
    if imgui.MenuItem1(_tr("editor.menu.unlockSelection"), "Ctrl+Shift+L", imgui_false, imgui_true) then
      editor.unlockObjectSelection()
    end
    imgui.Separator()
    if imgui.MenuItem1(_tr("editor.menu.hideSelection"), "Ctrl+H", imgui_false, imgui_true) then
      editor.hideObjectSelection()
    end
    if imgui.MenuItem1(_tr("editor.menu.showSelection"), "Ctrl+Shift+H", imgui_false, imgui_true) then
      editor.showObjectSelection()
    end
    imgui.Separator()

    if imgui.BeginMenu(_tr("editor.menu.alignBounds"), imgui_true) then
      if imgui.MenuItem1(_tr("editor.menu.negXAxis")) then
        editor.alignObjectSelectionByBounds(0)
      end
      if imgui.MenuItem1(_tr("editor.menu.posXAxis")) then
        editor.alignObjectSelectionByBounds(1)
      end
      if imgui.MenuItem1(_tr("editor.menu.negYAxis")) then
        editor.alignObjectSelectionByBounds(2)
      end
      if imgui.MenuItem1(_tr("editor.menu.posYAxis")) then
        editor.alignObjectSelectionByBounds(3)
      end
      if imgui.MenuItem1(_tr("editor.menu.negZAxis")) then
        editor.alignObjectSelectionByBounds(4)
      end
      if imgui.MenuItem1(_tr("editor.menu.posZAxis")) then
        editor.alignObjectSelectionByBounds(5)
      end
      imgui.EndMenu()
    end

    if imgui.BeginMenu(_tr("editor.menu.alignCenter"), nil, imgui_false, imgui_true) then
      if imgui.MenuItem1(_tr("editor.menu.xAxis")) then
        editor.alignObjectSelectionByCenter(0)
      end
      if imgui.MenuItem1(_tr("editor.menu.yAxis")) then
        editor.alignObjectSelectionByCenter(1)
      end
      if imgui.MenuItem1(_tr("editor.menu.zAxis")) then
        editor.alignObjectSelectionByCenter(2)
      end
      imgui.EndMenu()
    end

    if imgui.MenuItem1(_tr("editor.menu.moveSelectionInFrontOfCamera"), "Ctrl+Shift+J", imgui_false, imgui_true) then
      editor.moveSelectionAtCamera()
    end

    if imgui.MenuItem1(_tr("editor.menu.setSelectionTransformFromCamera"), "Ctrl+Shift+K", imgui_false, imgui_true) then
      editor.setObjectSelectionTransformFromCamera()
    end

    imgui.Separator()
    if imgui.MenuItem1(_tr("editor.menu.resetSelectedTransforms"), "Ctrl+Alt+R", imgui_false, imgui_true) then
      editor.resetObjectSelectionTransform()
    end
    if imgui.MenuItem1(_tr("editor.menu.resetSelectedRotations"), "Ctrl+Shift+R", imgui_false, imgui_true) then
      editor.resetObjectSelectionRotation()
    end
    if imgui.MenuItem1(_tr("editor.menu.resetSelectedScale"), nil, imgui_false, imgui_true) then
      editor.resetObjectSelectionScale()
    end
    imgui.EndMenu()
  end
end

local function windowMenu()
  if imgui.BeginMenu(_tr("editor.menu.window"), imgui_true) then
    local menuGenerator = function(menuGroups, menuItems)
        for _, item in ipairs(menuItems) do
          if item.isGroup then
            if imgui.BeginMenu(item.itemText, imgui_true) then
              for _, subitem in ipairs(menuGroups[item.itemText]) do
                if imgui.MenuItem1(subitem.itemText .. "##windowMenuItem_" .. makeWindowMenuKey(subitem), nil, imgui_false, imgui_true) then
                  if subitem.actionFunc then subitem.actionFunc() end
                end
              end
              imgui.EndMenu()
            end
          else
            if imgui.MenuItem1(item.itemText .. "##windowMenuItem_" .. makeWindowMenuKey(item), nil, imgui_false, imgui_true) then
              if item.actionFunc then item.actionFunc() end
            end
          end
        end
      end
    if editor.uiInputSearch(nil, windowSearchTxt, 240 * editor.getPreference("ui.general.scale")) then
      local s = ffi.string(windowSearchTxt)
      windowSearchDisplayResult = s:len() > 0
      if windowSearchDisplayResult then
        local addToSearch = function(menuGroups, menuItems)
          for _, item in ipairs(menuItems) do
            if item.isGroup then
              for _, subitem in ipairs(menuGroups[item.itemText]) do
                local entry = shallowcopy(subitem)
                entry.name = item.itemText.." > "..subitem.itemText
                entry.score = 1
                windowSearch:queryElement(entry)
              end
            else
              local entry = shallowcopy(item)
              entry.name = entry.itemText
              entry.score = 1
              windowSearch:queryElement(entry)
            end
          end
        end
        windowSearch:startSearch(s)
        addToSearch(defaultWindowMenuGroups, defaultWindowMenuItems)
        addToSearch(windowMenuGroups, windowMenuItems)
        windowSearchResults = windowSearch:finishSearch()
      end

    end
    imgui.Separator()

    if windowSearchDisplayResult then
      for _, item in ipairs(windowSearchResults) do
        if imgui.MenuItem1(item.name, nil, imgui_false, imgui_true) then
          ffi.fill(windowSearchTxt, imgui.ArraySize(windowSearchTxt))
          windowSearchDisplayResult = false
          if item.actionFunc then item.actionFunc() end
        end
      end
    else
      imgui.SeparatorText("Main Windows")
      menuGenerator(defaultWindowMenuGroups, defaultWindowMenuItems)
      local limit = getRecentWindowMenuLimit()
      local haveRecent = limit > 0 and #recentWindowMenuKeys > 0
      if haveRecent then
        -- Separator between built-in default tools and recently-used tools
        imgui.SeparatorText("Recent Windows")
          for _, key in ipairs(recentWindowMenuKeys) do
          local recentItem = findWindowMenuItemByKey(key)
          if recentItem and recentItem.actionFunc then
            if imgui.MenuItem1(key .. "##recentWindowMenuItem_" .. key, nil, imgui_false, imgui_true) then
              recentItem.actionFunc()
            end
          end
        end
      end
      -- Separator between recently-used tools and the rest of tools
      imgui.SeparatorText("All Windows")
      menuGenerator(windowMenuGroups, windowMenuItems)
    end

    imgui.EndMenu()
  end
end

local function helpMenu()
  if imgui.BeginMenu(_tr("editor.menu.help"), imgui_true) then
    if imgui.MenuItem1(_tr("editor.menu.editorDocumentation"), "F1", imgui_false, imgui_true) then
      editor.openHelp()
    end
    if imgui.MenuItem1(_tr("editor.menu.editorCodingDocumentation"), nil, imgui_false, imgui_true) then
      editor.openCodingHelp()
    end
    if imgui.MenuItem1(_tr("editor.menu.newsReleaseNotes"), nil, imgui_false, imgui_true) then
      editor.setPreference("newsMessage.general.newsMessageShown", false)
    end
    if imgui.MenuItem1(_tr("editor.menu.about"), nil, imgui_false, imgui_true) then
      editor.openModalWindow(aboutDlgName)
    end
    imgui.EndMenu()
  end
end

local saveLayoutWindow = imgui.BoolPtr(false)
local deleteLayoutWindow = imgui.BoolPtr(false)
local resetLayoutsWindow = imgui.BoolPtr(false)
local layoutName = imgui.ArrayChar(128)

local function viewMenu()
  if imgui.BeginMenu(_tr("editor.menu.view"), imgui_true) then
    drawGizmoPlane[0] = editor.getPreference("gizmos.general.drawGizmoPlane")
    if imgui.Checkbox(_tr("editor.menu.drawGizmoPlane") .. "    Ctrl+G", drawGizmoPlane) then
      editor.setPreference("gizmos.general.drawGizmoPlane", drawGizmoPlane[0])
    end

    displaySceneMetric[0] = editor.getPreference("ui.general.sceneMetric")
    if imgui.Checkbox(_tr("editor.menu.displaySceneMetric"), displaySceneMetric) then
      editor.setPreference("ui.general.sceneMetric", displaySceneMetric[0])
    end

    showCompleteSceneTree[0] = editor.getPreference("ui.general.showCompleteSceneTree")
    if imgui.Checkbox(_tr("editor.menu.showCompleteSceneTree"), showCompleteSceneTree) then
      editor.setPreference("ui.general.showCompleteSceneTree", showCompleteSceneTree[0])
    end

    local isShowNavGraphDrivabilityOn = editor.getVisualizationType("drawNavGraphdrivability")
    showNavGraphDrivability[0] = isShowNavGraphDrivabilityOn
    if imgui.Checkbox(_tr("editor.menu.drawNavgraphRoadDrivability"), showNavGraphDrivability) then
      editor.setVisualizationType("drawNavGraphdrivability", showNavGraphDrivability[0])
      if editor.updateVisSettings then
        editor.updateVisSettings()
      end
    end

    if imgui.BeginMenu(_tr("editor.menu.layouts"), imgui_true) then
      for _, layoutPath in ipairs(editor_layoutManager.getWindowLayouts()) do
        if imgui.MenuItem1(string.match(layoutPath, ".+/(.+)"), nil, imgui_false, imgui_true) then
          editor_layoutManager.loadWindowLayout(layoutPath)
        end
      end

      imgui.Separator()
      if imgui.MenuItem1(_tr("editor.menu.saveLayout"), nil, imgui_false, imgui_true) then
        editor.showWindow(saveLayoutWindowName)
      end
      if imgui.MenuItem1(_tr("editor.menu.deleteLayout"), nil, imgui_false, imgui_true) then
        editor.showWindow(deleteLayoutWindowName)
      end
      if imgui.MenuItem1(_tr("editor.menu.revertToFactorySettings"), nil, imgui_false, imgui_true) then
        editor.showWindow(resetLayoutsWindowName)
      end
      imgui.EndMenu()
    end

    if imgui.MenuItem1(_tr("editor.menu.visualizationSettings")) then
      editor.showWindow("visualization")
    end
    imgui.EndMenu()
  end
end

local function editorTitleGui()
  local windowSize = imgui.GetWindowContentRegionMax()
  extensions.hook("onEditorMainMenuBar", windowSize)
end

local function editorLevelTitleGui()
  imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1), "\tLevel: ")
  local str = "<none>"
  local modified = ""
  if editor.dirty then modified = "*" end
  imgui.TextColored(imgui.GetStyleColorVec4(imgui.Col_ButtonActive), "[" .. getMissionFilename() .. "]" .. modified)
end

local lastNotification = nil
local function notificationsGui()
  updateNotifications()
  if editor.currentNotificationIndex == 0 then return end
  local notification = editor.notificationQueue[editor.currentNotificationIndex]
  local textAlpha = 1

  if lastNotification ~= notification then
    lastNotification = notification
    if notification.doBeep or notification.doBeep == nil and editor.getPreference("ui.general.playSoundOnNotifications") == true then
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>Click_Tonal_02', {volume=1, pitch=1, fadeInTime=-1, fadeOutTime=-1, unique=true})
    end
  end

  if notification.time > notification.duration - notificationFadeTime then
    textAlpha = 1 - notification.time / notification.duration
  end

  imgui.TextColored(imgui.ImVec4(1, 1, 0, textAlpha), "\t"..notification.text)
end

local function currentEditModeGui()
  imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "\tEditMode: ")
  local str = "<none>"
  if editor.editMode then str = tostring(editor.editMode.displayName or editor.editMode.iconTooltip or "Unknown") end
  imgui.TextColored(imgui.GetStyleColorVec4(imgui.Col_ButtonActive), str)
end

--- Sets the current status bar text and optional UI. The status bar will be visible only when the text is non empty.
-- @param text the text shown in the status bar
-- @param uiCallback a function that will render additional imgui UI elements (progress bars, buttons etc), make sure to use imgui.SameLine() between them. (optional callback)
local function setStatusBar(text, uiCallback)
  editor.statusText = text
  editor.statusBarUiCallback = uiCallback
end

--- Hides the status bar. Please always use this function after your operation was completed.
local function hideStatusBar()
  editor.statusText = nil
  editor.statusBarUiCallback = nil
end

local function statusBarGui()
  if editor.statusText and editor.statusText ~= "" then
    local winbounds = imgui.GetMainViewport()
    --TODO: cannot properly position status bar window, needs precise values. It will break on UI scale other than 1
    imgui.SetNextWindowPos(imgui.ImVec2(winbounds.Pos.x + 15, winbounds.Pos.y + winbounds.Size.y - imgui.GetTextLineHeight()*3), imgui.Cond_Always)
    imgui.Begin("StatusBar", opened,
      bor(imgui.WindowFlags_NoTitleBar, imgui.WindowFlags_NoResize, imgui.WindowFlags_NoMove,
       imgui.WindowFlags_NoScrollbar, imgui.WindowFlags_AlwaysAutoResize, imgui.WindowFlags_NoBringToFrontOnFocus,
      imgui.WindowFlags_NoFocusOnAppearing, imgui.WindowFlags_NoNavFocus, imgui.WindowFlags_NoNavInputs,
      imgui.WindowFlags_NoNav))
    imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), editor.statusText)
    imgui.SameLine()
    if editor.statusBarUiCallback then editor.statusBarUiCallback() end
    imgui.End()
  end
end

local function getGpuMemoryTotalBytes(mem)
    if not mem then return end
    if mem.isDedicatedMemory and mem.dedicatedBytes and mem.dedicatedBytes > 0 then return mem.dedicatedBytes end
    if mem.sharedBytes and mem.sharedBytes > 0 then return mem.sharedBytes end
    if mem.dedicatedBytes and mem.dedicatedBytes > 0 then return mem.dedicatedBytes end
    return mem.budgetBytes
end

local function drawMetric(critical, warning, format, ...)
    local color = critical and metricCriticalColor or warning and metricWarningColor or imgui.GetStyleColorVec4(imgui.Col_Text)
    imgui.TextColored(color, format, ...)
end

local function memoryMetric(label, usedBytes, totalBytes)
    if not usedBytes or not totalBytes or totalBytes <= 0 then
        drawMetric(false, false, "%s: ?", label)
        return
    end

    local freeRatio = clamp((totalBytes - usedBytes) / totalBytes, 0, 1)
    drawMetric(freeRatio < 0.1, freeRatio < 0.25, "%s: %.1f/%.1f GiB", label, usedBytes / bytesPerGiB, totalBytes / bytesPerGiB)
end

local function sceneMetric()
  local io = imgui.GetIO()
  local fps = fpsSmoother:get(io.Framerate)

  local metricSpacing = 16 * imgui.uiscale[0]
  local metricsWidth = imgui.CalcTextSize("VRAM: 99.9/99.9 GiB").x + imgui.CalcTextSize("RAM: 99.9/99.9 GiB").x
    + imgui.CalcTextSize("FPS: 999").x + imgui.CalcTextSize("GpuWait: 00.0f").x + metricSpacing * 3
  imgui.SetCursorPosX(imgui.GetCursorPosX() + imgui.GetContentRegionAvailWidth() - metricsWidth + imgui.GetStyle().WindowPadding.x)

  if metricsTim < Engine.Platform.getRuntime() -0.5 then
    metricsTim = Engine.Platform.getRuntime()
    Engine.Debug.getLastPerformanceMetrics(metrics)
    systemMemoryInfo = Engine.Platform.getMemoryInfo()
    gpuMemoryInfo = Engine.Render.getMemoryInfo()
  end

  local gpuMemoryTotal = getGpuMemoryTotalBytes(gpuMemoryInfo)
  local gpuMemoryUsed = gpuMemoryInfo and gpuMemoryInfo.valid and gpuMemoryTotal and gpuMemoryInfo.availableBytes and math.max(0, gpuMemoryTotal - gpuMemoryInfo.availableBytes)
  memoryMetric("VRAM", gpuMemoryUsed, gpuMemoryTotal)
  imgui.SameLine(0, metricSpacing)
  memoryMetric("RAM", systemMemoryInfo and systemMemoryInfo.osPhysUsed, systemMemoryInfo and systemMemoryInfo.osPhysAvailable)
  imgui.SameLine(0, metricSpacing)

  drawMetric(fps < 30, fps < 60, "FPS: %.0f", fps)
  imgui.SameLine(0, metricSpacing)

  local gpuWait = metrics["FramePresent"]
  drawMetric(gpuWait >= 1 and fps <= 30, gpuWait >= 0.3, "GpuWait: %3.1f", gpuWait)
end

local function onEditorGuiMainMenu()
  if editor.safeMode then
    imgui.PushStyleColor1(imgui.Col_MenuBarBg, imgui.GetColorU322(imgui.ImVec4(0.3,0,0,1)))
  end

  if editor.headless then
    extensions.hook("onEditorHeadlessMainMenuBar", windowSize)
    return
  else
  if imgui.BeginMainMenuBar() then
    fileMenu()
    editMenu()
    cameraMenu()
    objectMenu()
    viewMenu()
    windowMenu()
    helpMenu()
    editor.menuHeight = imgui.GetWindowHeight()
    if editor.safeMode == true then
      editor.uiTextColoredWithFont(imgui.ImVec4(1, 0, 0, 1), "[ S A F E   M O D E ]", "cairo_bold")
    end
    editorLevelTitleGui()
    currentEditModeGui()
    editorTitleGui()
    notificationsGui()
    statusBarGui()
    if displaySceneMetric[0] then
      sceneMetric()
    end
    imgui.EndMainMenuBar()
    if editor.safeMode then
      imgui.PopStyleColor()
    end
    if openSafeModePopup then editor.openModalWindow(safeModeDlgName) openSafeModePopup = false end
    if editor.beginModalWindow(safeModeDlgName, _tr("editor.msgbox.safeMode"), imgui.WindowFlags_AlwaysAutoResize + imgui.WindowFlags_NoScrollbar) then
      imgui.Text(_tr("editor.msgbox.safeModeMessage"))
      if imgui.Button("OK", imgui.ImVec2(120, 0)) then editor.closeModalWindow(safeModeDlgName) end
    end
    editor.endModalWindow()

    if editor.beginModalWindow(aboutDlgName, _tr("editor.msgbox.aboutEditor"), imgui.WindowFlags_AlwaysAutoResize + imgui.WindowFlags_NoScrollbar) then
      local msg = core_locales.contextTranslate("editor.msgbox.aboutEditorMessage", {beamngVersion = beamng_versionb})
      imgui.Text(msg)
      if not shipping_build then
        imgui.Text("ImGui version: " .. imgui.GetVersion())
      end
      if imgui.Button("OK", imgui.ImVec2(120, 0)) then editor.closeModalWindow(aboutDlgName) end
    end
    editor.endModalWindow()
  end
  end

  if editor.beginWindow(revertLevelToOriginalWindowName, revertLevelToOriginalWindowTitle) then
    imgui.Text("Are you sure you want to revert current level to original content?")
    imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), "Warning: You will lose all your changes to the level!")
    if imgui.Button("Yes") then
      editor.hideWindow(revertLevelToOriginalWindowName)
      FS:directoryRemove(editor.getLevelPath())
      editor.openLevel(editor.getLevelPath())
    end
    imgui.SameLine()
    if imgui.Button("No") then
      editor.hideWindow(revertLevelToOriginalWindowName)
    end
  end
  editor.endWindow()

  if editor.beginWindow(saveLayoutWindowName, saveLayoutWindowTitle) then
    imgui.PushItemWidth(imgui.GetContentRegionAvailWidth())
      if imgui.InputText("##SaveLayout", layoutName, 128, imgui.InputTextFlags_EnterReturnsTrue) then
        editor.hideWindow(saveLayoutWindowName)
        editor_layoutManager.saveWindowLayout(ffi.string(layoutName))
      end
      if imgui.Button("Save") then
        editor.hideWindow(saveLayoutWindowName)
        editor_layoutManager.saveWindowLayout(ffi.string(layoutName))
      end
  end
  editor.endWindow()

  if editor.beginWindow(deleteLayoutWindowName, deleteLayoutWindowTitle) then
    for _, layoutPath in ipairs(editor_layoutManager.getWindowLayouts()) do
      if imgui.MenuItem1(string.match(layoutPath, ".+/(.+)"), nil, imgui_false, imgui_true) then
        editor_layoutManager.deleteWindowLayout(layoutPath)
      end
    end
  end
  editor.endWindow()

  if editor.beginWindow(resetLayoutsWindowName, resetLayoutsWindowTitle) then
    imgui.Text("This will delete all window layouts files and set the Default factory layout.")
    if imgui.Button("Continue") then
      editor.hideWindow(resetLayoutsWindowName)
      editor_layoutManager.resetLayouts()
    end
    imgui.SameLine()
    if imgui.Button("Cancel") then
      editor.hideWindow(resetLayoutsWindowName)
    end
  end
  editor.endWindow()
end

--- Add a new item in the main menu's `Window`.
-- if defaultToolWindow is true, then this is a window that opens by default in the editor, like Inspector and Scene Tree
-- and they will appear at the top of the Window menu, separated at the bottom with a menu separator, by other tool windows
-- @param itemText the text for the tools menu item
-- @param func the callback function called when the item is clicked
-- @param info [table] with info about this window menu item, with the following fields:
-- @param experimental [boolean] the extension tool is experimental if true, and it will be added to the Experimental submenu
-- @param gameplay [boolean] if true, then this extension tool will be shown on the gameplay Window menu (reduced editor, for gameplay only), but when full editor is on, it will also be visible in the Window menu
-- @param defaultToolWindow [boolean] if true, then this menu item will be shown at the top of the Window menu
local function addWindowMenuItem(itemText, actionFunc, info, defaultToolWindow)
  local item = {
    itemText = itemText,
    actionFunc = nil, -- set below (wrapped)
    info = info,
    menuGroupName = info and info.groupMenuName or nil,
    isDefaultToolWindow = defaultToolWindow or false
  }
  local originalActionFunc = actionFunc
  item.actionFunc = function()
    recordRecentWindowMenuItem(item)
    if extensions.telemetry_core then
      extensions.telemetry_core.addEvent({
        name = "editorToolWindowOpened",
        toolName = item.itemText,
        entryPoint = "windowMenu"
      })
    end
    if originalActionFunc then originalActionFunc() end
  end
  local menuGroups
  local menuItems

  -- if this item is a default window, we keep them on top
  if defaultToolWindow then
    menuGroups = defaultWindowMenuGroups
    menuItems = defaultWindowMenuItems
  else
    menuGroups = windowMenuGroups
    menuItems = windowMenuItems
  end

  if info then
    if info.groupMenuName then
      -- insert into custom group (create group if not existing)
      if nil == menuGroups[info.groupMenuName] then
        menuGroups[info.groupMenuName] = {}
        table.insert(menuItems, {isGroup = true, itemText = info.groupMenuName})
      end
      table.insert(menuGroups[info.groupMenuName], item)
      table.sort(menuGroups[info.groupMenuName], function(a, b) return a.itemText < b.itemText end)
    end
  else
    table.insert(menuItems, item)
  end

  table.sort(menuItems, function(a, b) return a.itemText < b.itemText end)
end

local function onExtensionLoaded()
  defaultWindowMenuItems = {}
  defaultWindowMenuGroups = {}
  windowMenuItems = {}
  windowMenuGroups = {}
  recentWindowMenuKeys = {}

  editor.notificationQueue = {}
  editor.maxNotificationCount = 100 -- how many notification messages to keep in the queue to be viewed
  editor.currentNotificationIndex = 0

  editor.addWindowMenuItem = addWindowMenuItem
  editor.showNotification = showNotification
  editor.setStatusBar = setStatusBar
  editor.hideStatusBar = hideStatusBar
  editor.rebuildCollision = rebuildCollision
end

local function onEditorActivated()
  worldEditorCppApi.setAxisGizmoRenderPlane(editor.getPreference("gizmos.general.drawGizmoPlane"))
  worldEditorCppApi.setAxisGizmoRenderPlaneHashes(editor.getPreference("gizmos.general.drawGizmoPlane"))
  worldEditorCppApi.setAxisGizmoRenderMoveGrid(editor.getPreference("gizmos.general.drawGizmoPlane"))
  worldEditorCppApi.setAxisGizmoHighlightSelectedMeshes(editor.getPreference("gizmos.general.highlightSelectedMeshes"))
end

local function onEditorInitialized()
  editor.registerWindow(saveLayoutWindowName, imgui.ImVec2(200, 100))
  editor.registerWindow(deleteLayoutWindowName, imgui.ImVec2(200, 100))
  editor.registerWindow(resetLayoutsWindowName, imgui.ImVec2(200, 100))
  editor.registerWindow(revertLevelToOriginalWindowName, imgui.ImVec2(300, 100))
  editor.registerModalWindow(aboutDlgName, nil, nil, true)
  editor.registerModalWindow(safeModeDlgName, nil, nil, true)

  local openSafeModePopupJob = function(job)
    job.sleep(1)
    openSafeModePopup = true
  end
  if editor.safeMode then
    --core_jobsystem.create(openSafeModePopupJob)
    openSafeModePopup = true
  end

  local isModLevel = false
  local levelName = core_levels.getLevelName(getMissionFilename())
  if levelName then
    local unpackedModsList = FS:findFiles( "/mods/unpacked/", "*", 0, false, true )
    for _, modPath in ipairs(unpackedModsList) do
      if FS:directoryExists(modPath.."/levels/"..levelName) and not FS:fileExists(modPath.."/levels/"..levelName) then
        isModLevel = true
        break
      end
    end
  end

  if (editor.getLevelPath() ~= "" and isOfficialContentVPath(editor.getLevelPath()) or isModLevel) then
    showRevertLevelToOriginalButton = true
  end
end

local function onEditorPreferenceValueChanged(path, value)
  if path == "ui.general.sceneMetric" then displaySceneMetric[0] = value end
  if path == "gizmos.visualization.visTypes" then
    showNavGraphDrivability[0] = value["drawNavGraphdrivability"] or false
  end
  if path == "ui.general.recentWindowMenuCount" then
    pruneRecentWindowMenuKeys()
  end
end

local function onEditorSaveState(state)
  -- Persist the MRU list into settings/editor/currentState.json
  state.windowMenuRecentTools = deepcopy(recentWindowMenuKeys)
end

local function onEditorLoadState(state)
  recentWindowMenuKeys = {}
  if state and type(state.windowMenuRecentTools) == "table" then
    for _, key in ipairs(state.windowMenuRecentTools) do
      if type(key) == "string" and key ~= "" then
        table.insert(recentWindowMenuKeys, key)
      end
    end
  end
  pruneRecentWindowMenuKeys()
end

M.onEditorGuiMainMenu = onEditorGuiMainMenu
M.onExtensionLoaded = onExtensionLoaded
M.onEditorActivated = onEditorActivated
M.onEditorInitialized = onEditorInitialized
M.onEditorPreferenceValueChanged = onEditorPreferenceValueChanged
M.onEditorSaveState = onEditorSaveState
M.onEditorLoadState = onEditorLoadState

return M