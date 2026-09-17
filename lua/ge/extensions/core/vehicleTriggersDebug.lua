-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local toolWindowName = "Vehicle event debug"

local M = {}
M.dependencies = {"core_vehicleTriggers", "core_vehicle_vehicleTriggerHighlight"}

local point00 = Point2I(0, 0)

local function queueCmd(vehId, cmd)
  local vehObj = scenetree.findObject(vehId)
  if vehObj then
    vehObj:queueLuaCommand(cmd)
    if core_vehicleTriggers and core_vehicleTriggers.state and core_vehicleTriggers.state.debugEnabled then
      log('I', 'triggers', 'Executing trigger code: ' .. tostring(cmd))
    end
  end
end

local function executeLink(vdata, lnk, actionValue, vehicleId)
  local value = actionValue
  if lnk and lnk.isInverted then
    value = -value
  end
  if lnk.version and lnk.version == 2 then
    if lnk.namespace == 'vehicle' then
      if not vdata.inputActions[lnk.inputAction] then
        log('E', 'triggers', 'input action not found: ' .. tostring(lnk.inputAction))
        return 0
      end
      return core_input_actions.executeCommand(vdata.inputActions[lnk.inputAction], value, vehicleId)
    elseif lnk.namespace == 'common' then
      if lnk.commonLua then
        if not vdata.inputActions[lnk.inputAction] then
          log('E', 'triggers', 'input action not found: ' .. tostring(lnk.inputAction))
          return 0
        end
        return core_input_actions.executeCommand(vdata.inputActions[lnk.inputAction], value, vehicleId)
      end
      if core_vehicleTriggers and core_vehicleTriggers.state and core_vehicleTriggers.state.debugEnabled then
        ActionMap.debugEnabled = true
      end
      local triggerdBindingCount = ActionMap.triggerBindingByNameDigital(lnk.inputAction, actionValue > 0.9, os.clockhp(), vehicleId)
      if core_vehicleTriggers and core_vehicleTriggers.state and core_vehicleTriggers.state.debugEnabled then
        ActionMap.debugEnabled = false
      end
      if core_vehicleTriggers and core_vehicleTriggers.state and core_vehicleTriggers.state.debugEnabled and triggerdBindingCount == 0 then
        log('W', 'triggers', 'No binding triggered: ' .. tostring(lnk.inputAction) .. ' for value ' .. tostring(value))
      end
    end
  else
    return core_input_actions.executeCommand(lnk.targetEvent, actionValue, vehicleId)
  end
  return 0
end

-- inputAction may be a string name or a numeric index into vehicle inputActions; prefer human-readable title.
local function getTriggerLinkActionDisplayText(vdata, lnk)
  local ia = lnk.inputAction
  if ia == nil then return "" end
  local acts = vdata.inputActions
  local act = acts and (acts[ia] or acts[tostring(ia)] or acts[tonumber(ia)])
  if act then
    local t = act.title or act.name
    if type(t) == "string" and t ~= "" then
      return _tr(t)
    end
  end
  return tostring(ia)
end

local function drawDebugUI(dt)
  if not core_vehicleTriggers or not core_vehicleTriggers.state then return end
  local state = core_vehicleTriggers.state

  im.SetNextWindowSize(im.ImVec2(500, 500), im.Cond_FirstUseEver)
  if im.Begin(toolWindowName, openPtr) then
    local tableFlags = bit.bor(im.TableFlags_BordersV,
    im.TableFlags_BordersOuterH,
    im.TableFlags_Resizable,
    im.TableFlags_RowBg)

    local stateOpen = im.TreeNodeEx1("State##vehicleTriggerState")
    if stateOpen then
      local activeCamName = state.activeCamName or "n/a"
      local lastCamFilter = core_camera and core_camera.getLastFilter and core_camera.getLastFilter() or "n/a"
      local hasController = false
      if Input and Input.getRegisteredDevices then
        for _, d in ipairs(Input.getRegisteredDevices()) do
          if d ~= "mouse0" and d ~= "keyboard0" then
            hasController = true
            break
          end
        end
      end
      local activeTrigger = state.currentlyUsedTrigger and (tostring(state.currentlyUsedTrigger.v) .. ":" .. tostring(state.currentlyUsedTrigger.t)) or "nil"
      local enabledNow = core_vehicleTriggers.isEnabled and core_vehicleTriggers.isEnabled()
      local hoveredHitWorld = state.hoveredHitPosWorld
      local hoveredHitScreen01 = state.hoveredHitPosScreen01
      local targetStream = state.crosshairTargetScreenStream or {}
      local labelX = targetStream.labelX
      local labelY = targetStream.labelY
      local labelTx = targetStream.labelTx
      local labelTy = targetStream.labelTy
      local labelSide = targetStream.labelSide
      local boundsMinX = targetStream.boundsMinX
      local boundsMaxX = targetStream.boundsMaxX
      local boundsMinY = targetStream.boundsMinY
      local boundsMaxY = targetStream.boundsMaxY
      local boundsCenterX = targetStream.boundsCenterX
      local boundsCenterY = targetStream.boundsCenterY
      local hasLabelPlacement = type(labelX) == "number" and type(labelY) == "number"
      local hasBounds = type(boundsMinX) == "number" and type(boundsMaxX) == "number" and type(boundsMinY) == "number" and type(boundsMaxY) == "number"
      local labelAnchorText = hasLabelPlacement and string.format("%.3f, %.3f", labelX, labelY) or "nil"
      local boundsMinText = hasBounds and string.format("%.3f, %.3f", boundsMinX, boundsMinY) or "nil"
      local boundsMaxText = hasBounds and string.format("%.3f, %.3f", boundsMaxX, boundsMaxY) or "nil"
      local boundsCenterText = (type(boundsCenterX) == "number" and type(boundsCenterY) == "number") and string.format("%.3f, %.3f", boundsCenterX, boundsCenterY) or "nil"
      local hoveredTriggerColorR = targetStream.colorR
      local hoveredTriggerColorG = targetStream.colorG
      local hoveredTriggerColorB = targetStream.colorB
      local hoveredTriggerColorA = targetStream.colorA
      local hoveredTriggerName = targetStream.hoveredTriggerName
      local hasHoveredTriggerColor =
        type(hoveredTriggerColorR) == "number"
        and type(hoveredTriggerColorG) == "number"
        and type(hoveredTriggerColorB) == "number"
      local hoveredTriggerColorText = hasHoveredTriggerColor
        and string.format(
          "%.3f, %.3f, %.3f, %.3f",
          hoveredTriggerColorR,
          hoveredTriggerColorG,
          hoveredTriggerColorB,
          type(hoveredTriggerColorA) == "number" and hoveredTriggerColorA or 1
        )
        or "nil"
      local hoveredTriggerColorDisplay = hasHoveredTriggerColor
        and im.ImVec4(hoveredTriggerColorR, hoveredTriggerColorG, hoveredTriggerColorB, 1)
        or im.ImVec4(0.8, 0.8, 0.8, 1)
      local actionMapsDesired = state.vehicleInteractionActionMapsDesired or {}
      local actionMapsActive = state.vehicleInteractionActionMapsActive or {}
      local hoveredHitWorldText = hoveredHitWorld and string.format("%.3f, %.3f, %.3f", hoveredHitWorld.x, hoveredHitWorld.y, hoveredHitWorld.z) or "nil"
      local hoveredHitScreen01Text = hoveredHitScreen01 and string.format("%.3f, %.3f", hoveredHitScreen01.x, hoveredHitScreen01.y) or "nil"

      local function drawStateRow(label, value, color)
        im.TableNextRow()
        im.TableNextColumn()
        im.TextUnformatted(label)
        im.TableNextColumn()
        im.PushStyleColor2(im.Col_Text, color or im.ImVec4(1, 1, 1, 1))
        im.TextUnformatted(tostring(value))
        im.PopStyleColor()
      end

      local function colorForBool(v)
        return v and im.ImVec4(0.2, 1, 0.2, 1) or im.ImVec4(1, 0.35, 0.35, 1)
      end

      im.TextUnformatted("Interaction availability")
      if im.BeginTable('StateAvailability##vehicleTriggerStateTable', 2, tableFlags) then
        im.TableSetupColumn("Key")
        im.TableSetupColumn("Value")
        drawStateRow("allowInteraction", state.allowInteraction, colorForBool(state.allowInteraction))
        drawStateRow("enabled(legacy fn)", enabledNow, colorForBool(enabledNow))
        drawStateRow("cefVisible", state.cefVisible, colorForBool(state.cefVisible))
        drawStateRow("cefMouseCaptured", state.cefMouseCaptured, colorForBool(not state.cefMouseCaptured))
        drawStateRow("mouseLocked", state.mouseLocked, colorForBool(not state.mouseLocked))
        drawStateRow("currentRoute", state.currentRouteName or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        drawStateRow("isPlayRoute", state.isPlayRoute, colorForBool(state.isPlayRoute))
        drawStateRow("activeCam", activeCamName, im.ImVec4(0.6, 0.9, 1, 1))
        drawStateRow("isUnicycle", state.isUnicycle, colorForBool(state.isUnicycle))
        drawStateRow("controllerConnected", hasController, colorForBool(hasController))
        drawStateRow("canUseVehicleTriggerCrosshair", state.canUseVehicleTriggerCrosshair, colorForBool(state.canUseVehicleTriggerCrosshair))
        drawStateRow("vehicleInteractionActionMapDesired", state.vehicleInteractionActionMapDesired, colorForBool(state.vehicleInteractionActionMapDesired))
        drawStateRow("vehicleInteractionActionMapActive", state.vehicleInteractionActionMapActive, colorForBool(state.vehicleInteractionActionMapActive))
        drawStateRow("VehicleInteraction0 desired", actionMapsDesired.action0 == true, colorForBool(actionMapsDesired.action0 == true))
        drawStateRow("VehicleInteraction1 desired", actionMapsDesired.action1 == true, colorForBool(actionMapsDesired.action1 == true))
        drawStateRow("VehicleInteraction2 desired", actionMapsDesired.action2 == true, colorForBool(actionMapsDesired.action2 == true))
        drawStateRow("VehicleInteraction0 active", actionMapsActive.action0 == true, colorForBool(actionMapsActive.action0 == true))
        drawStateRow("VehicleInteraction1 active", actionMapsActive.action1 == true, colorForBool(actionMapsActive.action1 == true))
        drawStateRow("VehicleInteraction2 active", actionMapsActive.action2 == true, colorForBool(actionMapsActive.action2 == true))
        drawStateRow("lastCamFilter", lastCamFilter, (lastCamFilter == FILTER_PAD) and im.ImVec4(0.2, 1, 0.2, 1) or im.ImVec4(1, 0.9, 0.25, 1))
        im.EndTable()
      end

      im.Separator()
      im.TextUnformatted("Aim mode computation")
      if im.BeginTable('StateAimMode##vehicleTriggerStateTable', 2, tableFlags) then
        im.TableSetupColumn("Key")
        im.TableSetupColumn("Value")
        drawStateRow("aimMode", state.aimMode or "nil", (state.aimMode == "crosshair") and im.ImVec4(0.6, 0.9, 1, 1) or im.ImVec4(0.9, 0.9, 0.6, 1))
        drawStateRow("cursorVisibility", state.cursorVisibility, colorForBool(state.cursorVisibility))
        drawStateRow("cursorVisible", state.cursorVisible, colorForBool(state.cursorVisible))
        drawStateRow("cameraMovementType", state.cameraMovementType, im.ImVec4(0.6, 0.9, 1, 1))
        drawStateRow("lastCameraMovementType", state.lastCameraMovementType, im.ImVec4(0.6, 0.9, 1, 1))
        drawStateRow("mouseInUse", state.mouseInUse, colorForBool(state.mouseInUse))
        drawStateRow("lastMousePos", state.lastMousePos and string.format("%0.3f, %0.3f", state.lastMousePos.x, state.lastMousePos.y) or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        drawStateRow("useCursorCoordinates", state.useCursorCoordinates, colorForBool(state.useCursorCoordinates))
        drawStateRow("triggerRange", core_vehicleTriggers.getTriggerRaycastDistance and core_vehicleTriggers.getTriggerRaycastDistance() or "n/a", im.ImVec4(0.6, 0.9, 1, 1))
        im.EndTable()
      end

      im.Separator()
      im.TextUnformatted("Crosshair and hover computation")
      if im.BeginTable('StateCrosshair##vehicleTriggerStateTable', 2, tableFlags) then
        im.TableSetupColumn("Key")
        im.TableSetupColumn("Value")
        drawStateRow("timeSinceLastMovedMs", state.timeSinceLastMovedMs == nil and "nil" or state.timeSinceLastMovedMs, im.ImVec4(0.6, 0.9, 1, 1))
        drawStateRow("crosshairTimedOut", state.crosshairTimedOut, colorForBool(state.crosshairTimedOut))
        drawStateRow("crosshairHasTarget", state.crosshairHasTarget, colorForBool(state.crosshairHasTarget))
        drawStateRow("currentlyUsedTrigger", activeTrigger, state.currentlyUsedTrigger and im.ImVec4(0.2, 1, 0.2, 1) or im.ImVec4(0.8, 0.8, 0.8, 1))
        drawStateRow("crosshairVisible", state.crosshairVisible, colorForBool(state.crosshairVisible))
        drawStateRow("vehicleTriggerCrosshairVisible(stream)", state.crosshairVisibleStream == nil and "nil" or state.crosshairVisibleStream, state.crosshairVisibleStream == nil and im.ImVec4(0.8, 0.8, 0.8, 1) or colorForBool(state.crosshairVisibleStream))
        drawStateRow("vehicleTriggerCrosshairHovered(stream)", state.crosshairHoveredStream == nil and "nil" or state.crosshairHoveredStream, state.crosshairHoveredStream == nil and im.ImVec4(0.8, 0.8, 0.8, 1) or colorForBool(state.crosshairHoveredStream))
        drawStateRow("hoveredHitPosWorld", hoveredHitWorldText, hoveredHitWorld and im.ImVec4(0.6, 0.9, 1, 1) or im.ImVec4(0.8, 0.8, 0.8, 1))
        drawStateRow("hoveredHitPosScreen01", hoveredHitScreen01Text, hoveredHitScreen01 and im.ImVec4(0.6, 0.9, 1, 1) or im.ImVec4(0.8, 0.8, 0.8, 1))
        drawStateRow("hoveredTriggerName(stream)", hoveredTriggerName or "nil", hoveredTriggerName and im.ImVec4(0.6, 0.9, 1, 1) or im.ImVec4(0.8, 0.8, 0.8, 1))
        drawStateRow("hoveredTriggerColor(stream)", hoveredTriggerColorText, hoveredTriggerColorDisplay)
        im.EndTable()
      end

      im.Separator()
      local labelPlacementOpen = im.TreeNodeEx1("Label placement##vehicleTriggerLabelPlacement")
      if labelPlacementOpen then
        if im.BeginTable('StateLabelPlacement##vehicleTriggerStateTable', 2, tableFlags) then
          im.TableSetupColumn("Key")
          im.TableSetupColumn("Value")
          drawStateRow("hasLabelPlacement(stream)", hasLabelPlacement, colorForBool(hasLabelPlacement))
          drawStateRow("labelSide(stream)", labelSide or "nil", im.ImVec4(0.6, 0.9, 1, 1))
          drawStateRow("labelAnchor01(stream)", labelAnchorText, hasLabelPlacement and im.ImVec4(0.6, 0.9, 1, 1) or im.ImVec4(0.8, 0.8, 0.8, 1))
          drawStateRow("labelTranslateX(stream)", labelTx or "nil", im.ImVec4(0.6, 0.9, 1, 1))
          drawStateRow("labelTranslateY(stream)", labelTy or "nil", im.ImVec4(0.6, 0.9, 1, 1))
          drawStateRow("hasBounds(stream)", hasBounds, colorForBool(hasBounds))
          drawStateRow("boundsMin01(stream)", boundsMinText, hasBounds and im.ImVec4(0.6, 0.9, 1, 1) or im.ImVec4(0.8, 0.8, 0.8, 1))
          drawStateRow("boundsMax01(stream)", boundsMaxText, hasBounds and im.ImVec4(0.6, 0.9, 1, 1) or im.ImVec4(0.8, 0.8, 0.8, 1))
          drawStateRow("boundsCenter01(stream)", boundsCenterText, (type(boundsCenterX) == "number" and type(boundsCenterY) == "number") and im.ImVec4(0.6, 0.9, 1, 1) or im.ImVec4(0.8, 0.8, 0.8, 1))
          im.EndTable()
        end
        im.TreePop()
      end
      im.TreePop()
    end

    local mouseTrackingOpen = im.TreeNodeEx1("Mouse tracking##vehicleTriggerMouseTracking")
    if mouseTrackingOpen then
      local canvas = scenetree.findObject("Canvas")
      local cursorPos = canvas and canvas.getCursorPos and canvas:getCursorPos() or nil
      local imguiMousePos = im.GetMousePos and im.GetMousePos() or nil
      local clientW, clientH = nil, nil
      local windowLeft, windowTop, windowWidth, windowHeight = nil, nil, nil, nil
      local clientOriginX, clientOriginY = nil, nil
      if canvas and canvas.getWindowClientSizeXY then
        clientW, clientH = canvas:getWindowClientSizeXY()
      end
      if canvas and canvas.getWindowBounds then
        windowLeft, windowTop, windowWidth, windowHeight = canvas:getWindowBounds()
      end
      if canvas and canvas.clientToScreenXY then
        clientOriginX, clientOriginY = canvas:clientToScreenXY(point00)
      end

      local cursorX = cursorPos and cursorPos.x or nil
      local cursorY = cursorPos and cursorPos.y or nil
      local cursorLocalX, cursorLocalY = nil, nil
      if cursorX and cursorY and clientOriginX and clientOriginY then
        cursorLocalX = cursorX - clientOriginX
        cursorLocalY = cursorY - clientOriginY
      end
      local cursorPercent01 = core_vehicleTriggers.getCursorPercent01 and core_vehicleTriggers.getCursorPercent01() or nil
      local cursorXPct = cursorPercent01 and cursorPercent01.x or nil
      local cursorYPct = cursorPercent01 and cursorPercent01.y or nil

      local function fmtNum(v)
        if v == nil then return "nil" end
        return string.format("%.3f", v)
      end

      local function drawMouseRow(label, value, color)
        im.TableNextRow()
        im.TableNextColumn()
        im.TextUnformatted(label)
        im.TableNextColumn()
        im.PushStyleColor2(im.Col_Text, color or im.ImVec4(1, 1, 1, 1))
        im.TextUnformatted(tostring(value))
        im.PopStyleColor()
      end

      local function colorForMouseBool(v)
        return v and im.ImVec4(0.2, 1, 0.2, 1) or im.ImVec4(1, 0.35, 0.35, 1)
      end

      if im.BeginTable('MouseTracking##vehicleTriggerMouseTrackingTable', 2, tableFlags) then
        im.TableSetupColumn("Key")
        im.TableSetupColumn("Value")
        drawMouseRow("canvasFound", canvas ~= nil, colorForMouseBool(canvas ~= nil))
        drawMouseRow("windowBoundsPx", (windowLeft and windowTop and windowWidth and windowHeight) and string.format("l=%d t=%d w=%d h=%d", windowLeft, windowTop, windowWidth, windowHeight) or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        drawMouseRow("windowClientOriginPx", (clientOriginX and clientOriginY) and string.format("%.1f, %.1f", clientOriginX, clientOriginY) or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        drawMouseRow("canvasCursorPosScreenPx", (cursorX and cursorY) and string.format("%.1f, %.1f", cursorX, cursorY) or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        drawMouseRow("canvasCursorPosWindowPx", (cursorLocalX and cursorLocalY) and string.format("%.1f, %.1f", cursorLocalX, cursorLocalY) or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        drawMouseRow("windowClientSizePx", (clientW and clientH) and string.format("%d x %d", clientW, clientH) or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        drawMouseRow("cursorPercent01Window", (cursorXPct and cursorYPct) and (fmtNum(cursorXPct) .. ", " .. fmtNum(cursorYPct)) or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        drawMouseRow("cursorPercent100Window", (cursorXPct and cursorYPct) and string.format("%.2f%%, %.2f%%", cursorXPct * 100, cursorYPct * 100) or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        drawMouseRow("imguiMousePosPx", (imguiMousePos and string.format("%.1f, %.1f", imguiMousePos.x, imguiMousePos.y)) or "nil", im.ImVec4(0.6, 0.9, 1, 1))
        im.EndTable()
      end
      im.TreePop()
    end
    im.Separator()

    for i = 0, be:getObjectCount() - 1 do
      local veh = be:getObject(i)
      local vehId = veh:getId()
      local vData = extensions.core_vehicle_manager.getVehicleData(vehId)

      local open = im.TreeNodeEx1("Vehicle " .. tostring(vehId) .. '##vehicle' .. tostring(vehId))
      im.SameLine()
      im.PushStyleColor2(im.Col_Text, im.ImVec4(0, 1, 0, 1))
      local title = ''
      if vData.vdata then
        title = tostring(vData.vdata.model)
      end
      im.TextUnformatted(title)
      im.PopStyleColor()
      im.SameLine()
      im.PushStyleColor2(im.Col_Text, im.ImVec4(0, 1, 1, 1))
      if vData.config then
        local _, filename, _ = path.splitWithoutExt(tostring(vData.config.partConfigFilename))
        im.TextUnformatted(filename)
      end
      im.PopStyleColor()
      im.SameLine()
      im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 0, 1, 1))
      im.TextUnformatted(vehId == be:getPlayerVehicleID(0) and ' [ACTIVE]' or '')
      im.PopStyleColor()

      if open then
        local triggerCount = vData.vdata.maxIDs and vData.vdata.maxIDs.triggers or 0
        local open2 = im.TreeNodeEx1("Triggers##triggers" .. tostring(vehId))
        im.SameLine()
        im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 1, 0, 1))
        im.TextUnformatted(tostring(triggerCount))
        im.PopStyleColor()

        if open2 then
          if im.BeginTable('Triggers##vehicleTriggers' .. tostring(vehId), 5, tableFlags) then
            im.TableSetupScrollFreeze(0, 1)
            im.TableSetupColumn("Id")
            im.TableSetupColumn("Name")
            im.TableSetupColumn("Action")
            im.TableSetupColumn("Namespace")
            im.TableSetupColumn("Controls")
            im.TableHeadersRow()
            im.TableNextRow()
            if vData and vData.vdata and type(vData.vdata.triggers) == 'table' then
              for _, trg in pairs(vData.vdata.triggers or {}) do
                for actionStr, lnkTable in pairs(vData.vdata.triggerEventLinksDict[trg.cid] or {}) do
                  if lnkTable and #lnkTable > 0 then
                    for _, lnk in pairs(lnkTable) do
                      local isSelected = core_vehicle_vehicleTriggerHighlight and core_vehicle_vehicleTriggerHighlight.isHighlightedTrigger and core_vehicle_vehicleTriggerHighlight.isHighlightedTrigger(vehId, trg.cid)
                      if isSelected then
                        im.PushStyleColor2(im.Col_TableRowBg, im.ImVec4(0.0, 0.5, 0.0, 1.0))
                        im.PushStyleColor2(im.Col_TableRowBgAlt, im.ImVec4(0.0, 0.5, 0.0, 1.0))
                      end
                      im.TableNextColumn()
                      if im.SmallButton(tostring(trg.cid) .. '##trigger_' .. tostring(trg.cid) .. '_' .. tostring(vehId)) then
                        dump(trg)
                      end
                      im.TableNextColumn()
                      im.Text(_tr(trg.name))
                      im.TableNextColumn()

                      if lnk.triggerInput then
                        im.Text(getTriggerLinkActionDisplayText(vData.vdata, lnk))
                        im.TableNextColumn()
                        im.TextUnformatted(tostring(lnk.namespace))
                        if lnk.namespace == 'common' then
                          im.SameLine()
                          im.TextUnformatted(tostring(lnk.commonLua and "[LUA]" or "[C++]"))
                        end
                        local origin = trg.originSection
                        if origin ~= nil and origin ~= '' and origin ~= 'triggers2' then
                          im.SameLine()
                          im.TextUnformatted(' (' .. tostring(origin) .. ')')
                        end
                        im.TableNextColumn()
                        im.SmallButton((tostring(lnk.triggerInput) or 'trigger') .. '##lnk2_' .. tostring(lnk.cid) .. '_' .. tostring(vehId))
                        if im.IsItemHovered() and im.IsMouseClicked(0) then executeLink(vData.vdata, lnk, 1, vehId) end
                        if im.IsItemHovered() and im.IsMouseReleased(0) then executeLink(vData.vdata, lnk, 0, vehId) end
                      elseif lnk.targetEvent then
                        im.TextUnformatted(tostring(lnk.action) .. ' - ' .. tostring(lnk.targetEvent.name))
                        im.SameLine()
                        im.SmallButton('trigger##lnk_' .. tostring(lnk.cid) .. '_' .. tostring(vehId))
                        if im.IsItemHovered() and im.IsMouseClicked(0) then executeLink(vData.vdata, lnk, 1, vehId) end
                        if im.IsItemHovered() and im.IsMouseReleased(0) then executeLink(vData.vdata, lnk, 0, vehId) end
                        im.TableNextRow()
                      end

                      im.SameLine()
                      if isSelected then
                        if im.SmallButton('un-highlight##highlight_' .. tostring(trg.cid) .. '_' .. tostring(actionStr)) then
                          core_vehicle_vehicleTriggerHighlight.unhighlightTrigger(vehId, trg.cid)
                        end
                      elseif im.SmallButton('highlight##highlight_' .. tostring(trg.cid) .. '_' .. tostring(actionStr)) then
                        core_vehicle_vehicleTriggerHighlight.setHighlightedTrigger(vehId, trg.cid)
                      end

                      im.TableNextRow()
                      if isSelected then
                        im.PopStyleColor(2)
                      end
                    end
                  end
                end
              end
            end
            im.EndTable()
          end
          im.TreePop()
        end

        local eventsCount = vData.vdata.maxIDs and vData.vdata.maxIDs.events or 0
        local open3 = im.TreeNodeEx1("Events##Events" .. tostring(vehId))
        im.SameLine()
        im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 1, 0, 1))
        im.TextUnformatted(tostring(eventsCount))
        im.PopStyleColor()

        if open3 then
          if im.BeginTable('Events##vehicleEventNames' .. tostring(vehId), 4, tableFlags) then
            im.TableSetupScrollFreeze(0, 1)
            im.TableSetupColumn("Id")
            im.TableSetupColumn("Name")
            im.TableSetupColumn("Description")
            im.TableSetupColumn("Controls")
            im.TableHeadersRow()
            if vData and vData.vdata and type(vData.vdata.events) == 'table' then
              for _, evt in pairs(vData.vdata.events or {}) do
                im.TableNextRow()
                im.TableNextColumn()
                im.TextUnformatted(tostring(evt.cid))
                im.TableNextColumn()
                im.Text(_tr(evt.name))
                im.TableNextColumn()
                im.Text(_tr(evt.desc))
                im.TableNextColumn()

                im.SmallButton('trigger##u' .. tostring(evt.cid) .. '_' .. tostring(vehId))
                if im.IsItemHovered() and im.IsMouseClicked(0) and evt.onDown then queueCmd(vehId, evt.onDown) end
                if im.IsItemHovered() and im.IsMouseReleased(0) and evt.onUp then queueCmd(vehId, evt.onUp) end
              end
            end
            im.EndTable()
          end
          im.TreePop()
        end
        im.TreePop()
      end
    end
  end
  im.End()

end

local function onUpdate(dtReal, dtSim, dtRaw)
  drawDebugUI(dtReal)
end

local function onSerialize()
  local highlightedData = nil
  if core_vehicle_vehicleTriggerHighlight and core_vehicle_vehicleTriggerHighlight.getSerializedHighlightedTriggerData then
    highlightedData = core_vehicle_vehicleTriggerHighlight.getSerializedHighlightedTriggerData()
  end
  return {
    highLightedTriggerData = highlightedData,
  }
end

local function onDeserialized(data)
  if data and core_vehicle_vehicleTriggerHighlight and core_vehicle_vehicleTriggerHighlight.setSerializedHighlightedTriggerData then
    core_vehicle_vehicleTriggerHighlight.setSerializedHighlightedTriggerData(data.highLightedTriggerData)
  end
end

M.onUpdate = onUpdate
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
