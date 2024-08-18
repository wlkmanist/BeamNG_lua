-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui

local logTag = "editor_trafficSignals"
local editWindowName = "Traffic Signals Editor"
local editModeName = "signalsEditMode"

local instances, controllers, sequences, elements, controllerDefinitions = {}, {}, {}, {}, {}
local signalIdx, ctrlIdx, sequenceIdx, phaseIdx = 1, 1, 1, 1
local signalName, ctrlName, sequenceName, selectedObject
local colorWarning = im.ImVec4(1, 1, 0, 1)
local dummyVec = im.ImVec2(0, 5)
local lastUsed = {signalType = "lightsBasic"}
local timedTexts = {}
local oldTransform = {pos = vec3(), rot = quat(), scl = 1}
local options = {displayNameMode = 1, smartSelection = true, showClosestRoad = false}
local tabFlags = {}
local signalObjects = {}
local signalObjectFlags = {}
local selectableControllers = {}
local isDragging = false
local overwriteDialog = false
local itemWidth = 100
local trafficSignals

local mousePos = vec3()
local vecUp = vec3(0, 0, 1)
local vecUp5 = vec3(0, 0, 5)
local vecY = vec3(0, 1, 0)
local cylinderRadius = 0.25
local debugColors = {
  main = ColorF(1, 1, 1, 0.4),
  selected = ColorF(1, 1, 0.25, 0.4),
  guide = ColorF(0.25, 1, 0.25, 0.4),
  road = ColorF(0.25, 0.5, 0.1, 0.4),
  error = ColorF(1, 0.25, 0.25, 0.4)
}

local currNode, currSignalObj
local firstLoad, running = true, false

local function staticRayCast()
  local rayCastHit
  if core_forest.getForestObject() then core_forest.getForestObject():disableCollision() end
  local rayCast = cameraMouseRayCast()
  if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end

  if rayCast then rayCastHit = vec3(rayCast.pos) end
  return rayCastHit
end

local function updateGizmoTransform()
  local data = instances[signalIdx]
  if data then
    local nodeTransform = MatrixF(true)
    nodeTransform:setPosition(data.pos)
    editor.setAxisGizmoTransform(nodeTransform)
  end
end

local function selectInstance(idx)
  idx = idx or 1
  local instance = instances[idx]
  if not instance then return end

  signalName = im.ArrayChar(256, instance.name)
  signalIdx = idx
  table.clear(signalObjects)
  table.clear(signalObjectFlags)
  table.clear(selectableControllers)
  updateGizmoTransform()
end

local function selectController(idx)
  idx = idx or 1
  local ctrl = controllers[idx]
  if not ctrl then return end

  ctrlName = im.ArrayChar(256, ctrl.name)
  ctrlIdx = idx
end

local function selectSequence(idx)
  idx = idx or 1
  local sequence = sequences[idx]
  if not sequence then return end

  sequenceName = im.ArrayChar(256, sequence.name)
  sequenceIdx = idx
  phaseIdx = 1
end

local function resetSignals()
  table.clear(instances)
  table.clear(controllers)
  table.clear(sequences)
  signalIdx, ctrlIdx, sequenceIdx, phaseIdx = 1, 1, 1, 1
  lastUsed = {signalType = "lightsBasic"}
end

local function getSerializedSignals() -- error checks and serializes the current signals data
  local instancesSerialized, controllersSerialized, sequencesSerialized = {}, {}, {}

  for _, instance in ipairs(instances) do
    table.insert(instancesSerialized, instance:onSerialize())
  end
  for _, ctrl in ipairs(controllers) do
    table.insert(controllersSerialized, ctrl:onSerialize())
  end
  for _, sequence in ipairs(sequences) do
    table.insert(sequencesSerialized, sequence:onSerialize())
  end

  return {instances = instancesSerialized, controllers = controllersSerialized, sequences = sequencesSerialized}
end

local function getCurrentSignals() -- returns the signals data from the editor
  return {instances = instances, controllers = controllers, sequences = sequences}
end

local function setCurrentSignals(data) -- directly sets the signals data for the editor
  data = data or core_trafficSignals.getData()
  data.instances = data.instances or {}
  data.controllers = data.controllers or {}
  data.sequences = data.sequences or {}
  resetSignals()

  for _, instance in ipairs(data.instances) do
    instance.pos = vec3(instance.pos)
    instance.dir = vec3(instance.dir)
    local new = trafficSignals.newSignal(instance)
    table.insert(instances, new)
    elements[new.id] = new
  end
  for _, ctrl in ipairs(data.controllers) do
    local new = trafficSignals.newController(ctrl)
    table.insert(controllers, new)
    elements[new.id] = new
  end
  for _, sequence in ipairs(data.sequences) do
    local new = trafficSignals.newSequence(sequence)
    table.insert(sequences, new)
    elements[new.id] = new
  end

  selectInstance(signalIdx)
  selectController(ctrlIdx)
  selectSequence(sequenceIdx)
end

local function loadFile(fileName) -- loads the main signals data
  fileName = fileName or editor.levelPath.."signals.json"
  local data = jsonReadFile(fileName)
  if data then
    if not data.intersections then
      setCurrentSignals(data)
    else
      log("W", logTag, "Obsolete signals data!")
      setCurrentSignals({})
    end
  end
end

local function saveFile(fileName) -- saves the main signals data
  fileName = fileName or editor.levelPath.."signals.json"
  jsonWriteFile(fileName, getSerializedSignals(), true)
  timedTexts.save = {"Signals saved!", 3}
end

local function simulate(val) -- runs the simulation for the traffic lights
  if val then
    for _, sequence in ipairs(sequences) do
      sequence.enableTestTimer = true
    end

    trafficSignals.setupSignals(getCurrentSignals()) -- also activates the signals
    trafficSignals.debugLevel = 2
    map.reset() -- TEMP: this forces the mapmgr signals to update
    running = true
  else
    trafficSignals.setActive(false)
    trafficSignals.debugLevel = 0
    running = false
  end
end

local function createInstanceActionUndo(data)
  table.remove(instances, data.deleteIdx or #instances)
  signalIdx = math.max(1, signalIdx - 1)
  selectInstance(signalIdx)
end

local function createInstanceActionRedo(data)
  table.insert(instances, trafficSignals.newSignal(data))
  signalIdx = #instances
  instances[signalIdx].name = data.name or "Signal "..signalIdx
  elements[instances[signalIdx].id] = instances[signalIdx]
  selectInstance(signalIdx)
end

local function transformInstanceActionUndo(data)
  instances[signalIdx].pos:set(data.oldTransform.pos)
  instances[signalIdx].dir = vecY:rotated(data.oldTransform.rot)
  instances[signalIdx].radius = clamp(data.oldTransform.scl, 1, 100)
  instances[signalIdx].road = nil
  updateGizmoTransform()
end

local function transformInstanceActionRedo(data)
  instances[signalIdx].pos:set(data.newTransform.pos)
  instances[signalIdx].dir = vecY:rotated(data.newTransform.rot)
  instances[signalIdx].radius = clamp(data.newTransform.scl, 1, 100)
  instances[signalIdx].road = nil
  updateGizmoTransform()
end

local function createControllerActionUndo(data)
  table.remove(controllers, data.deleteIdx or #controllers)
  ctrlIdx = math.max(1, ctrlIdx - 1)
  selectController(ctrlIdx)
end

local function createControllerActionRedo(data)
  table.insert(controllers, trafficSignals.newController())
  ctrlIdx = #controllers
  controllers[ctrlIdx]:onDeserialized(data)
  controllers[ctrlIdx].name = data.name or "Controller "..ctrlIdx
  elements[controllers[ctrlIdx].id] = controllers[ctrlIdx]
  selectController(ctrlIdx)
end

local function createSequenceActionUndo(data)
  table.remove(sequences, data.deleteIdx or #sequences)
  controllers[ctrlIdx]:deleteSignal(signalIdx)
  sequenceIdx = math.max(1, sequenceIdx - 1)
  selectController(sequenceIdx)
end

local function createSequenceActionRedo(data)
  table.insert(sequences, trafficSignals.newSequence())
  sequenceIdx = #sequences
  sequences[sequenceIdx]:onDeserialized(data)
  sequences[sequenceIdx].name = data.name or "Sequence "..sequenceIdx
  elements[sequences[sequenceIdx].id] = sequences[sequenceIdx]
  selectSequence(sequenceIdx)
end

local function gizmoBeginDrag()
  if instances[signalIdx] then
    instances[signalIdx].rot = quatFromDir(instances[signalIdx].dir, vecUp)
    oldTransform.pos = vec3(instances[signalIdx].pos)
    oldTransform.rot = quat(instances[signalIdx].rot)
    oldTransform.scl = instances[signalIdx].radius
  end
end

local function gizmoEndDrag()
  if instances[signalIdx] then
    isDragging = false
    local newTransform = {
      pos = vec3(instances[signalIdx].pos),
      rot = quat(instances[signalIdx].rot),
      scl = instances[signalIdx].radius
    }

    local act = {oldTransform = oldTransform, newTransform = newTransform}
    editor.history:commitAction("Transform Signal Instance", act, transformInstanceActionUndo, transformInstanceActionRedo)
  end
end

local function gizmoMidDrag()
  if instances[signalIdx] then
    isDragging = true
    if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
      instances[signalIdx].pos:set(editor.getAxisGizmoTransform():getColumn(3))
    elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
      local rotation = QuatF(0, 0, 0, 1)
      rotation:setFromMatrix(editor.getAxisGizmoTransform())

      if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
        instances[signalIdx].rot = quat(rotation)
      else
        instances[signalIdx].rot = oldTransform.rot * quat(rotation)
      end
      instances[signalIdx].dir = vecY:rotated(instances[signalIdx].rot)
    elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
      local scl = vec3(editor.getAxisGizmoScale())
      local sclMin, sclMax = math.min(scl.x, scl.y, scl.z), math.max(scl.x, scl.y, scl.z)
      instances[signalIdx].radius = clamp(sclMin < 1 and oldTransform.scl * sclMin or oldTransform.scl * sclMax, 1, 100)
    end
  end
end

local function tabInstances()
  im.BeginChild1("instances", im.ImVec2(150 * im.uiscale[0], 0), im.WindowFlags_ChildWindow)
  for i, instance in ipairs(instances) do
    if im.Selectable1(instance.name, signalIdx == i) then
      selectInstance(i)
    end
  end
  im.Separator()

  im.Selectable1("New...##instance", false)
  im.tooltip("Shift-Click in the world to create a new signal instance point.")
  im.EndChild()
  im.SameLine()

  im.BeginChild1("instanceData", im.ImVec2(0, 0), im.WindowFlags_ChildWindow)
  itemWidth = im.GetContentRegionAvailWidth() * 0.5
  if not im.IsWindowHovered(im.HoveredFlags_AnyWindow) and not signalObjectFlags.selectObjects and editor.keyModifiers.shift and mousePos then
    debugDrawer:drawTextAdvanced(mousePos, "Create Signal Instance", ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 255))

    if im.IsMouseClicked(0) then
      local act = {pos = mousePos, controllerId = lastUsed.controllerId, sequenceId = lastUsed.sequenceId}
      editor.history:commitAction("Create Signal Instance", act, createInstanceActionUndo, createInstanceActionRedo)
      selectInstance(signalIdx)
    end
  end

  local currInstance = instances[signalIdx]
  if currInstance then
    im.TextUnformatted("Current Signal: "..currInstance.name.." ["..currInstance.id.."]")

    im.SameLine()
    if im.Button("Delete##instance") then
      local act = instances[signalIdx]:onSerialize()
      act.deleteIdx = signalIdx
      editor.history:commitAction("Delete Signal Instance", act, createInstanceActionRedo, createInstanceActionUndo)
    end

    im.PushItemWidth(itemWidth)
    if editor.uiInputText("Name##instance", signalName, nil, im.InputTextFlags_EnterReturnsTrue) then
      currInstance.name = ffi.string(signalName)
    end
    im.PopItemWidth()

    local signalPos = im.ArrayFloat(3)
    local changed = false
    signalPos[0], signalPos[1], signalPos[2] = currInstance.pos.x, currInstance.pos.y, currInstance.pos.z

    im.PushItemWidth(itemWidth)
    if im.InputFloat3("Position##instance", signalPos, "%0."..editor.getPreference("ui.general.floatDigitCount").."f", im.InputTextFlags_EnterReturnsTrue) then
      changed = true
    end
    im.PopItemWidth()
    if im.Button("Down to Terrain##instance") then
      if core_terrain.getTerrain() then
        signalPos[2] = core_terrain.getTerrainHeight(currInstance.pos)
        changed = true
      end
    end

    if changed then -- commits changes to history
      gizmoBeginDrag()
      instances[signalIdx].pos = vec3(signalPos[0], signalPos[1], signalPos[2])
      gizmoEndDrag()
    end

    im.Dummy(dummyVec)

    ---- select sequence for signal instance ----
    local elem = elements[currInstance.sequenceId]
    local name = elem and elem.name or "Basic"

    im.PushItemWidth(itemWidth)
    if im.BeginCombo("Sequence (Signal Group)##instance", name) then
      if im.Selectable1("Basic##instanceSequenceBasic", not elem) then
        currInstance:setSequence(0)
        lastUsed.sequenceId = 0
        table.clear(selectableControllers)
      end
      for _, sequence in ipairs(sequences) do
        if im.Selectable1(sequence.name.."##instanceSequence", sequence.name == name) then
          currInstance:setSequence(sequence.id)
          lastUsed.sequenceId = sequence.id
          table.clear(selectableControllers)
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()

    if currInstance.sequenceId > 0 then
      if im.Button("Edit##instanceSequence") or currInstance._newSequence then
        tabFlags = {im.flags(im.TabItemFlags_None), im.flags(im.TabItemFlags_None), im.flags(im.TabItemFlags_SetSelected)}
        currInstance._newSequence = nil
        for i, sequence in ipairs(sequences) do
          if sequence.id == currInstance.sequenceId then
            selectSequence(i)
          end
        end
      end
    else
      if im.Button("New...##instanceSequence") then
        editor.history:commitAction("Create Sequence", {}, createSequenceActionUndo, createSequenceActionRedo)
        currInstance.sequenceId = sequences[#sequences].id
        currInstance._newSequence = true
      end
    end

    -- update selectable controllers here
    if not selectableControllers[1] then
      local sequence = elements[currInstance.sequenceId]
      if sequence then
        local temp = {}
        for _, phase in ipairs(sequence.phases) do
          for _, data in ipairs(phase.controllerData) do
            if elements[data.id] and not temp[data.id] then
              table.insert(selectableControllers, elements[data.id])
              temp[data.id] = 1
            end
          end
        end
      else
        for _, ctrl in ipairs(controllers) do
          table.insert(selectableControllers, ctrl)
        end
      end
    end

    ---- select controller for signal instance ----
    elem = elements[currInstance.controllerId]
    name = elem and elem.name or "(None)"

    im.PushItemWidth(itemWidth)
    if im.BeginCombo("Controller (Signal Type)##instance", name) then
      if im.Selectable1("(None)##instanceController", not elem) then
        currInstance:setController(0)
        lastUsed.controllerId = 0
      end
      -- only controllers found within the current sequence should be selectable
      for _, ctrl in ipairs(selectableControllers) do
        if im.Selectable1(ctrl.name, ctrl.name == name) then
          currInstance:setController(ctrl.id)
          lastUsed.controllerId = ctrl.id
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()

    if currInstance.controllerId > 0 then
      if im.Button("Edit##instanceCtrl") or currInstance._newController then
        tabFlags = {im.flags(im.TabItemFlags_None), im.flags(im.TabItemFlags_SetSelected), im.flags(im.TabItemFlags_None)}
        currInstance._newController = nil
        for i, ctrl in ipairs(controllers) do
          if ctrl.id == currInstance.controllerId then
            selectController(i)
          end
        end
      end
    else
      if im.Button("New...##instanceCtrl") then
        editor.history:commitAction("Create Controller", {}, createControllerActionUndo, createControllerActionRedo)
        currInstance.controllerId = controllers[#controllers].id
        currInstance._newController = true
      end
    end

    if not currInstance.road then
      currInstance.road = currInstance:getBestRoad()
      if not currInstance.road then
        im.TextColored(colorWarning, "Warning, could not find closest road node!")
      end
    end

    im.Dummy(dummyVec)
    im.Separator()
    im.TextUnformatted("Signal Objects")

    if timedTexts.signalObjects then
      im.Dummy(dummyVec)
      im.TextWrapped(timedTexts.signalObjects[1])
    elseif timedTexts.applyFields then
      im.TextColored(colorWarning, timedTexts.applyFields[1])
    else
      im.TextUnformatted(" ")
    end

    im.Dummy(dummyVec)

    if not signalObjectFlags.objectsNotFound and not signalObjects[1] then
      signalObjects = currInstance:getSignalObjects(true)
      signalObjectFlags.objectsNotFound = not signalObjects[1] and true or false
    end

    local selectObjects = signalObjectFlags.selectObjects and true or false
    if not selectObjects then
      if im.Button("Select Objects##signalObjects") then
        signalObjectFlags.selectObjects = true
        editor.selectEditMode(editor.editModes["objectSelect"])
        timedTexts.selectObjects = {"Currently in Object Selection mode.", 5000}
      end
      im.tooltip("Enables object selection mode to select signal objects.")

      local val = im.BoolPtr(options.smartSelection)
      if im.Checkbox("Smart Selection Mode", val) then
        options.smartSelection = val[0]
      end
      im.tooltip("If true, objects with the same type and rotation will be added to the selection.")
    else
      if options.smartSelection then
        -- whenever a single object is selected, all others of the same type, area, and rotation are also selected
        -- use internalName if you want to group varying traffic light shapes together
        -- otherwise, this will only match by shapeName

        -- maybe this should be a function
        if signalObjectFlags.smartSelectObjects then
          local selectedObj = scenetree.findObjectById(editor.selection.object[1])
          local validIds = {}
          if selectedObj:getClassName() == "TSStatic" then
            local internalName = selectedObj:getInternalName()

            local dir1 = selectedObj:getTransform():getForward()
            for _, obj in ipairs(getObjectsByClass("TSStatic") or {}) do
              if (internalName and obj:getInternalName() == internalName) or obj.shapeName == selectedObj.shapeName then
                if selectedObj:getPosition():squaredDistance(obj:getPosition()) <= 1600 then -- checks within a 40 m radius
                  -- strong assumption that the TSStatics were created with the same initial rotation
                  local dir2 = obj:getTransform():getForward()
                  if dir1:dot(dir2) >= 0.93 then -- roughly within 20 degrees
                    table.insert(validIds, obj:getId())
                  end
                end
              end
            end
          end

          if validIds[2] then
            editor.selectObjects(validIds)
          end
          signalObjectFlags.smartSelectObjects = nil
        end
      end

      local count = tableSize(editor.selection.object)
      if im.Button("Confirm Selection ("..count..")##signalObjects") then
        if count > 0 then
          for _, id in ipairs(editor.selection.object) do
            editor.setDynamicFieldValue(id, "signalInstance", currInstance.name)
          end
          editor.selectEditMode(editor.editModes[editModeName])
          editor.selection.object = nil
          table.clear(signalObjects)
          table.clear(signalObjectFlags)
          timedTexts.selectObjects = nil
          timedTexts.signalObjects = nil
          timedTexts.applyFields = {"Updated "..count.." objects: [signalInstance] = "..currInstance.name, 6}
        end
      end
      im.tooltip("Apply the dynamic field [signalInstance] to objects in this selection.")
      im.SameLine()

      if im.Button("Cancel##signalObjects") then
        editor.selectEditMode(editor.editModes[editModeName])
        editor.selection.object = nil
        table.clear(signalObjects)
        table.clear(signalObjectFlags)
      end

      if timedTexts.selectObjects then
        im.TextColored(colorWarning, timedTexts.selectObjects[1])
      end
    end

    im.Dummy(dummyVec)

    if signalObjectFlags.objectsNotFound then
      im.TextUnformatted("No linked objects found.")
    else
      if im.Button("View Selection##signalObjects") then
        if not selectedObject and signalObjects[1] then
          editor.selectObjects({signalObjects[1]})
          selectedObject = signalObjects[1]
        end
        editor.fitViewToSelection()
      end
      im.SameLine()
      if im.Button("Clear Object Fields##signalObjects") then
        for _, id in ipairs(signalObjects) do
          scenetree.findObjectById(id).signalInstance = ""
        end
        editor.selection.object = nil
        table.clear(signalObjects)
        table.clear(signalObjectFlags)
      end

      im.BeginChild1("signalObjects", im.ImVec2(itemWidth, 150 * im.uiscale[0]), im.WindowFlags_ChildWindow)
      for _, oid in ipairs(signalObjects) do
        local obj = scenetree.findObjectById(oid)
        if obj then
          if im.Selectable1(tostring(oid), selectedObject == oid) then
            editor.selectObjects({oid})
            selectedObject = oid
          end
        end
      end
      im.EndChild()
    end

    if mousePos and editor.isViewportHovered() and im.IsMouseClicked(0) and not editor.isAxisGizmoHovered() and not editor.keyModifiers.shift then
      for i, instance in ipairs(instances) do
        if mousePos:squaredDistance(instance.pos) <= cylinderRadius * 2 then
          selectInstance(i)
        end
      end
      updateGizmoTransform()
    end
    editor.updateAxisGizmo(gizmoBeginDrag, gizmoEndDrag, gizmoMidDrag)
    editor.drawAxisGizmo()
  end
  im.EndChild()
end

local function tabControllers()
  table.clear(selectableControllers)

  im.BeginChild1("controllers", im.ImVec2(150 * im.uiscale[0], 0), im.WindowFlags_ChildWindow)

  for i, ctrl in ipairs(controllers) do
    if im.Selectable1(ctrl.name, ctrlIdx == i) then
      selectController(i)
    end
  end
  im.Separator()
  if im.Selectable1("Create...##controller", false) then
    editor.history:commitAction("Create Controller", {}, createControllerActionUndo, createControllerActionRedo)
  end
  im.EndChild()
  im.SameLine()

  im.BeginChild1("controllerData", im.ImVec2(0, 0), im.WindowFlags_ChildWindow)
  itemWidth = im.GetContentRegionAvailWidth() * 0.5
  local currController = controllers[ctrlIdx]
  if currController then
    im.TextUnformatted("Current Controller: "..currController.name.." ["..currController.id.."]")

    im.SameLine()
    if im.Button("Delete##controller") then
      local act = currController:onSerialize()
      act.deleteIdx = ctrlIdx
      editor.history:commitAction("Delete Controller", act, createControllerActionRedo, createControllerActionUndo)
    end

    im.PushItemWidth(itemWidth)
    if editor.uiInputText("Name##controller", ctrlName, nil, im.InputTextFlags_EnterReturnsTrue) then
      currController.name = ffi.string(ctrlName)
    end
    im.PopItemWidth()

    local currCtrlType = currController.type
    if currCtrlType == "none" then
      currController.type = lastUsed.signalType or "none"
    end
    local signalTypes = core_trafficSignals.getControllerDefinitions().types
    local typeName = signalTypes[currCtrlType] and signalTypes[currCtrlType].name or "(None)"

    im.PushItemWidth(itemWidth)
    if im.BeginCombo("Signal Type##controller", typeName) then
      for _, k in ipairs(tableKeysSorted(signalTypes)) do
        if im.Selectable1(signalTypes[k].name, k == currController.type) then
          currController.type = k
          lastUsed.signalType = k
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()

    if currController.type ~= currCtrlType then
      currController:applyDefinition(currController.type)
    end

    im.Dummy(dummyVec)
    im.Separator()
    im.TextUnformatted("States")

    im.Dummy(dummyVec)

    if currController.isSimple or not currController.states[1] then
      for _, state in ipairs(currController.states) do
        local stateData = currController:getStateData(state.state)
        if stateData then
          im.TextUnformatted(stateData.name)
        end
      end

      im.Dummy(dummyVec)
      im.TextUnformatted("No settings available for this controller.")
    else
      for i, state in ipairs(currController.states) do
        local stateData = currController:getStateData(state.state)
        if stateData then
          state.duration = state.duration or -1

          local var = im.FloatPtr(state.duration)
          im.PushItemWidth(100 * im.uiscale[0])
          if im.InputFloat(stateData.name.."##controllerState"..i, var, 0.1, 0.1, "%.2f", im.InputTextFlags_EnterReturnsTrue) then
            state.duration = math.max(0, var[0])
          end
          if state.state == "redTrafficLight" then
            im.tooltip("This is usually the delay time until the next signal phase starts.")
          end

          im.SameLine()
          if im.Button("Set Infinite##controllerState"..i) then
            state.duration = -1
          end
        end
      end
    end
  end
  im.EndChild()
end

local function tabSequences()
  table.clear(selectableControllers)

  im.BeginChild1("sequences", im.ImVec2(150 * im.uiscale[0], 0), im.WindowFlags_ChildWindow)

  for i, sequence in ipairs(sequences) do
    if im.Selectable1(sequence.name, sequenceIdx == i) then
      selectSequence(i)
    end
  end
  im.Separator()
  if im.Selectable1("Create...##sequence", false) then
    editor.history:commitAction("Create Sequence", {}, createSequenceActionUndo, createSequenceActionRedo)
  end
  im.EndChild()
  im.SameLine()

  im.BeginChild1("sequenceData", im.ImVec2(0, 0), im.WindowFlags_ChildWindow)
  itemWidth = im.GetContentRegionAvailWidth() * 0.5
  local currSequence = sequences[sequenceIdx]
  if currSequence then
    im.TextUnformatted("Current Sequence: "..currSequence.name.." ["..currSequence.id.."]")

    im.SameLine()
    if im.Button("Delete##sequence") then
      local act = currSequence:onSerialize()
      act.deleteIdx = sequenceIdx
      editor.history:commitAction("Delete Sequence", act, createSequenceActionRedo, createSequenceActionUndo)
    end

    im.PushItemWidth(itemWidth)
    if editor.uiInputText("Name##sequence", sequenceName, nil, im.InputTextFlags_EnterReturnsTrue) then
      currSequence.name = ffi.string(sequenceName)
    end
    im.PopItemWidth()

    local var = im.FloatPtr(currSequence.startTime)
    im.PushItemWidth(100 * im.uiscale[0])
    if im.InputFloat("Start Delay##sequence", var, 0.01, 0.1, "%.2f", im.InputTextFlags_EnterReturnsTrue) then
      currSequence.startTime = var[0]
    end
    im.PopItemWidth()
    im.tooltip("This can also be negative, to skip ahead in the sequence.")

    var = im.BoolPtr(currSequence.startDisabled)
    if im.Checkbox("Start Disabled##sequence", var) then
      currSequence.startDisabled = var[0]
    end
    im.tooltip("If true, this sequence starts with all signals in the off state.")

    im.Dummy(dummyVec)
    im.Separator()
    im.TextUnformatted("Phases")

    im.Dummy(dummyVec)

    if im.Button("Create##sequencePhase") then
      currSequence:createPhase()
      phaseIdx = #currSequence.phases
    end
    im.SameLine()
    if im.Button("Delete##sequencePhase") then
      currSequence:deletePhase()
      if not currSequence.phases[phaseIdx] then
        phaseIdx = math.max(1, #currSequence.phases)
      end
    end

    for i, phase in ipairs(currSequence.phases) do
      local isCurrentPhase = i == phaseIdx
      if isCurrentPhase then
        im.PushStyleColor2(im.Col_Button, im.GetStyleColorVec4(im.Col_ButtonActive))
      end
      if im.Button(" "..i.." ") then
        phaseIdx = i
      end
      if isCurrentPhase then
        im.PopStyleColor()
      end
      im.SameLine()
    end
    im.Dummy(dummyVec)

    local phase = currSequence.phases[phaseIdx]
    if phase then
      im.TextUnformatted("Phase #"..phaseIdx)

      im.Dummy(dummyVec)
      im.TextUnformatted("Controllers")
      local count = #phase.controllerData
      if count <= 0 then
        table.insert(phase.controllerData, {id = 0, required = true})
        count = 1
      end

      var = im.IntPtr(count)
      im.PushItemWidth(100 * im.uiscale[0])
      if im.InputInt("Count##phaseController", var, 1) then
        while var[0] > #phase.controllerData do
          table.insert(phase.controllerData, {id = 0, required = true})
        end
        while var[0] < #phase.controllerData do
          table.remove(phase.controllerData, #phase.controllerData)
        end
      end
      im.PopItemWidth()

      local controllersDict = {}
      for _, cd in ipairs(phase.controllerData) do
        controllersDict[cd.id] = 1
      end

      for j, cd in ipairs(phase.controllerData) do
        im.PushItemWidth(itemWidth)
        if im.BeginCombo("Controller #"..j.."##phaseController", elements[cd.id] and elements[cd.id].name or "(None)") then
          for _, ctrl in ipairs(controllers) do
            if not controllersDict[ctrl.id] and im.Selectable1(ctrl.name, cd.id == ctrl.id) then
              cd.id = ctrl.id
            end
          end
          im.EndCombo()
        end
        im.PopItemWidth()
      end

      im.Dummy(dummyVec)
      im.TextWrapped("Advance to the next phase when these controller cycles are complete:")

      im.BeginChild1("controllerRequirements", im.ImVec2(itemWidth, 150 * im.uiscale[0]), im.WindowFlags_ChildWindow)
      for _, cd in ipairs(phase.controllerData) do
        if elements[cd.id] then
          local isRequired = cd.required
          if isRequired then
            im.PushStyleColor2(im.Col_Header, im.GetStyleColorVec4(im.Col_ButtonActive))
          end
          if im.Selectable1(elements[cd.id].name, cd.required) then
            cd.required = not cd.required
          end
          if isRequired then
            im.PopStyleColor()
          end
        end
      end
      im.EndChild()
    end
  end
  im.EndChild()
end

local function tabSimulation()
  if instances[1] then
    if not running then
      if im.Button("Play") then
        simulate(true)
      end
    else
      local debugData = trafficSignals.getData()
      if im.Button("Stop") then
        simulate(false)
      end
      im.SameLine()
      if debugData.active then
        if im.Button("Pause##simulation") then
          core_trafficSignals.setActive(false)
        end
      else
        if im.Button("Resume##simulation") then
          core_trafficSignals.setActive(true)
        end
      end
    end
    if not be:getEnabled() then
      im.SameLine()
      im.TextColored(colorWarning, "Main simulation is currently paused.")
    end

    if running then
      local debugData = trafficSignals.getData()
      if debugData.nextTime then
        im.TextUnformatted("Current timer: "..tostring(string.format("%.2f", debugData.timer)))
        im.TextUnformatted("Next event time: "..tostring(string.format("%.2f", debugData.nextTime)))
      end

      im.Dummy(dummyVec)
      im.Separator()

      local columnWidth = im.GetContentRegionAvailWidth() * 0.24
      im.Columns(4)
      im.SetColumnWidth(0, columnWidth)
      im.SetColumnWidth(1, columnWidth)
      im.SetColumnWidth(2, columnWidth)

      for i, sequence in ipairs(core_trafficSignals.getSequences()) do
        im.TextUnformatted(sequence.name)

        im.NextColumn()
        im.TextUnformatted("Step: "..sequence.currStep)

        im.NextColumn()
        local currTime = sequence.testTimer or 0
        local maxTime = math.max(1e-6, sequence.sequenceDuration)
        im.ProgressBar(currTime / maxTime, im.ImVec2(im.GetContentRegionAvailWidth(), 0))

        im.NextColumn()
        if im.Button("Advance##simulation"..i) then
          if sequence.active then
            sequence:advance()
          else
            sequence:setActive(true)
          end
        end
        im.SameLine()
        if not sequence.ignoreTimer then
          if im.Button("Pause##simulation"..i) then
            sequence:enableTimer(false)
          end
        else
          if im.Button("Resume##simulation"..i) then
            sequence:enableTimer(true)
          end
        end

        im.NextColumn()
      end
      im.Columns(1)
    end
  else
    im.TextUnformatted("Signals need to exist before running simulation.")
    running = false
  end
end

local function debugDraw()
  if running then return end

  local mapNodes = map.getMap().nodes

  for i, instance in ipairs(instances) do
    local alpha = signalIdx == i and 1 or 0.5
    local camDist = instance.pos:squaredDistance(core_camera.getPosition())
    if camDist <= square(editor.getPreference("gizmos.visualization.visualizationDrawDistance")) or signalIdx == i then
      local str = instance.name
      local strColor = ColorF(1, 1, 1, alpha)
      if options.displayNameMode == 2 then
        str = elements[instance.controllerId] and elements[instance.controllerId].name or "(Null controller)"
        strColor = ColorF(0, 1, 0, alpha)
      elseif options.displayNameMode == 3 then
        str = elements[instance.sequenceId] and elements[instance.sequenceId].name or "(Null sequence)"
        strColor = ColorF(0, 1, 1, alpha)
      end

      local shapeColor = signalIdx == i and debugColors.selected or debugColors.main

      if signalIdx == i and instance.road then
        shapeColor = debugColors.selected
      end

      if signalIdx == i then
        debugDrawer:drawSphere(instance.pos, cylinderRadius * 2, debugColors.main)
        if isDragging then
          debugDrawer:drawSphere(instance.pos, instance.radius, ColorF(1, 1, 1, 0.1))
        end

        if options.showClosestRoad and instance.road and instance.road.n1 then
          debugDrawer:drawSphere(mapNodes[instance.road.n1].pos, cylinderRadius, debugColors.road)
          debugDrawer:drawSphere(mapNodes[instance.road.n2].pos, cylinderRadius, debugColors.road)
          debugDrawer:drawSquarePrism(mapNodes[instance.road.n1].pos, mapNodes[instance.road.n2].pos, Point2F(0.2, 0.2), Point2F(0.2, 0.2), debugColors.road)
        end

        for _, oid in ipairs(signalObjects) do
          local obj = scenetree.findObjectById(oid)
          if obj then
            local abovePos = obj:getWorldBox():getCenter()
            abovePos.z = abovePos.z + obj:getWorldBox():getExtents().z * 0.5 + 0.25
            debugDrawer:drawSquarePrism(abovePos, abovePos + vecUp, Point2F(0, 0), Point2F(0.5, 0.5), debugColors.selected)
          end
        end
      end

      local instancePosUp = instance.pos + vecUp5
      debugDrawer:drawCylinder(instance.pos, instancePosUp, cylinderRadius, shapeColor)
      debugDrawer:drawSquarePrism(instance.pos, instance.pos + instance.dir * instance.radius, Point2F(0.5, instance.radius * 0.25), Point2F(0.5, 0), debugColors.guide)
      debugDrawer:drawTextAdvanced(instance.pos, String(str), strColor, true, false, ColorI(0, 0, 0, alpha * 255))

      if camDist <= 10000 then -- draw signal cylinder cap that represents each controller
        local r, g, b = 0, 0, 0
        if elements[instance.controllerId] then
          for sci, sc in ipairs(selectableControllers) do
            if instance.controllerId == sc.id then
              r, g, b = HSVtoRGB(sci / (#selectableControllers + 1), 1, 1)
              break
            end
          end
        end
        debugDrawer:drawCylinder(instancePosUp, instancePosUp + vecUp * 0.5, cylinderRadius, ColorF(r, g, b, 0.6))
      end
    end
  end
end

local displayNameModesSorted = {"Signals", "Controllers", "Sequences"}
local function onEditorGui(dt)
  if editor.beginWindow(editModeName, editWindowName, im.WindowFlags_MenuBar) then
    if firstLoad then
      editor.selectEditMode(editor.editModes[editModeName])
      trafficSignals = extensions.core_trafficSignals
      trafficSignals.loadControllerDefinitions(editor.levelPath.."signalControllerDefinitions.json")
      controllerDefinitions = trafficSignals.getControllerDefinitions()

      if not instances[1] then
        setCurrentSignals() -- automatically loads active signals data from map
      end

      selectInstance(signalIdx)
      selectController(ctrlIdx)
      selectSequence(sequenceIdx)

      timedTexts.signalObjects = {"Select signal objects in the level to link with this instance. Remember to Save Level (Ctrl+S) if signal objects were assigned or updated.", 5000}

      firstLoad = false
    end

    mousePos = staticRayCast()

    im.BeginMenuBar()
    if im.BeginMenu("File") then
      if im.MenuItem1("Load") then
        loadFile()
      end
      if im.MenuItem1("Save") then
        saveFile()
      end
      if im.MenuItem1("Clear") then
        overwriteDialog = true
      end
      im.EndMenu()
    end
    if im.BeginMenu("Preferences") then
      if im.BeginMenu("Display Name Mode") then
        for mi, mode in ipairs(displayNameModesSorted) do
          if im.Selectable1(mode, mode == displayNameModesSorted[options.displayNameMode]) then
            options.displayNameMode = mi
          end
        end
        im.EndMenu()
      end

      local var = im.BoolPtr(options.showClosestRoad)
      if im.Checkbox("Draw Closest Road Segment", var) then
        options.showClosestRoad = var[0]
      end

      im.EndMenu()
    end

    if timedTexts.save then
      im.SameLine()
      im.TextColored(colorWarning, timedTexts.save[1])
    end
    im.EndMenuBar()

    if overwriteDialog then
      im.SetNextWindowPos(im.GetCursorScreenPos())
      if im.Begin("Confirm##trafficSignals", im.BoolPtr(true), bit.bor(im.WindowFlags_NoDocking, im.WindowFlags_NoCollapse)) then
        im.TextUnformatted("Are you sure you want to clear signals data?")
        if im.Button("YES") then
          im.CloseCurrentPopup()
          overwriteDialog = false
          resetSignals()
        end
        im.SameLine()
        if im.Button("NO") then
          im.CloseCurrentPopup()
          overwriteDialog = false
        end
      end
      im.End()
    end

    if im.BeginTabBar("Signal Tools") then
      if im.BeginTabItem("Signals", nil, tabFlags[1]) then
        tabInstances()
        im.EndTabItem()
      end
      if im.BeginTabItem("Controllers", nil, tabFlags[2]) then
        tabControllers()
        im.EndTabItem()
      end
      if im.BeginTabItem("Sequences", nil, tabFlags[3]) then
        tabSequences()
        im.EndTabItem()
      end
      if im.BeginTabItem("Simulation", nil, tabFlags[4]) then
        tabSimulation()
        im.EndTabItem()
      end
      im.EndTabBar()
    end
    table.clear(tabFlags)

    debugDraw()
  end

  for k, v in pairs(timedTexts) do
    if v[2] then
      v[2] = v[2] - dt
      if v[2] <= 0 then timedTexts[k] = nil end
    end
  end

  editor.endWindow()
end

local function onActivate()
  editor.clearObjectSelection()
end

local function onEditorObjectSelectionChanged()
  if signalObjectFlags.selectObjects and options.smartSelection and tableSize(editor.selection.object) == 1 and not signalObjectFlags.smartSelectObjects then
    signalObjectFlags.smartSelectObjects = true
  end
end

local function onClientEndMission()
  firstLoad = true
end

local function onSerialize()
  local data = {options = options, signals = getSerializedSignals()}
  return data
end

local function onDeserialized(data)
  trafficSignals = core_trafficSignals
  options = data.options
  setCurrentSignals(data.signals)
end

local function onWindowMenuItem()
  firstLoad = true
  editor.clearObjectSelection()
  editor.showWindow(editModeName)
end

local function onEditorInitialized()
  editor.registerWindow(editModeName, im.ImVec2(540, 600))
  editor.editModes[editModeName] = {
    displayName = editWindowName,
    onActivate = onActivate,
    auxShortcuts = {}
  }
  editor.editModes[editModeName].auxShortcuts[bit.bor(editor.AuxControl_LMB, editor.AuxControl_Shift)] = "Create Signal"
  editor.editModes[editModeName].auxShortcuts[editor.AuxControl_LMB] = "Select"
  editor.addWindowMenuItem(editWindowName, onWindowMenuItem, {groupMenuName = "Gameplay"})
end

M.getCurrentSignals = getCurrentSignals
M.setCurrentSignals = setCurrentSignals
M.loadFile = loadFile
M.saveFile = saveFile

M.onEditorInitialized = onEditorInitialized
M.onWindowMenuItem = onWindowMenuItem
M.onEditorGui = onEditorGui
M.onEditorObjectSelectionChanged = onEditorObjectSelectionChanged
M.onClientEndMission = onClientEndMission
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M