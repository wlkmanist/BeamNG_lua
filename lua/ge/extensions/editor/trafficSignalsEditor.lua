-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui

local logTag = "editor_trafficSignals"
local editWindowName = "Traffic Signals Editor"
local editModeName = "signalsEditMode"

local instances, controllers, sequences, elements, controllerDefinitions = {}, {}, {}, {}, {}
local groups, groupsSorted = {}, {}
local selected = {signal = 1, controller = 1, sequence = 1, phase = 1, ctrlDefState = 1, ctrlDefType = 1, group = 1, flashingLight = 1}
local signalName, ctrlName, sequenceName, selectedObject, signalCtrlDefinitions
local ctrlDefinitionStateName, ctrlDefinitionTypeName, instanceGroupName
local colorWarning = im.ImVec4(1, 1, 0, 1)
local colorError = im.ImVec4(1, 0, 0, 1)
local dummyVec = im.ImVec2(0, 5)
local iconVec = im.ImVec2(24, 24)

local lastUsed = {signalType = "lightsBasic"}
local timedTexts = {}
local oldTransform = {pos = vec3(), rot = quat(), scl = 1}
local options = {displayNameMode = 1, smartSelection = true, showClosestRoad = false}
local windowFlags = {overwrite = im.BoolPtr(false), instanceGroups = im.BoolPtr(false), ctrlDefinitions = im.BoolPtr(false)}
local tabFlags = {}
local signalObjects = {}
local signalObjectFlags = {}
local selectableControllers = {}
local groupsEdited = false
local isDragging = false
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
  local data = instances[selected.signal]
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
  selected.signal = idx
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
  selected.controller = idx
end

local function selectSequence(idx)
  idx = idx or 1
  local sequence = sequences[idx]
  if not sequence then return end

  sequenceName = im.ArrayChar(256, sequence.name)
  selected.sequence = idx
  selected.phase = 1
end

local function updateGroups() -- resolves all signal instance groups
  table.clear(groups)
  for i, instance in ipairs(instances) do
    instance._idx = i
    if instance.group then
      if not groups[instance.group] then
        groups[instance.group] = {}
      end
      table.insert(groups[instance.group], instance.id)
    end
  end

  groupsSorted = tableKeysSorted(groups)
end

local function resetSignals() -- resets editor signals data
  table.clear(instances)
  table.clear(controllers)
  table.clear(sequences)
  table.clear(groups)
  table.clear(groupsSorted)
  selected.signal, selected.controller, selected.sequence, selected.phase = 1, 1, 1, 1
  lastUsed = {signalType = "lightsBasic"}
end

local function getSerializedSignals() -- returns serialized signals data (intended for save data)
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
  data = data or core_trafficSignals.getData() -- uses current level signal data by default
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

  selectInstance(selected.signal)
  selectController(selected.controller)
  selectSequence(selected.sequence)

  updateGroups()
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
  elements[instances[data.deleteIdx].id] = nil
  table.remove(instances, data.deleteIdx or #instances)
  selected.signal = math.max(1, selected.signal - 1)
  updateGroups()
  selectInstance(selected.signal)
end

local function createInstanceActionRedo(data)
  table.insert(instances, trafficSignals.newSignal(data))
  selected.signal = #instances
  instances[selected.signal].name = data.name or "Signal "..selected.signal
  elements[instances[selected.signal].id] = instances[selected.signal]
  updateGroups()
  selectInstance(selected.signal)
end

local function transformInstanceActionUndo(data)
  instances[selected.signal].pos:set(data.oldTransform.pos)
  instances[selected.signal].dir = vecY:rotated(data.oldTransform.rot)
  instances[selected.signal].radius = clamp(data.oldTransform.scl, 1, 100)
  instances[selected.signal].road = nil
  updateGizmoTransform()
end

local function transformInstanceActionRedo(data)
  instances[selected.signal].pos:set(data.newTransform.pos)
  instances[selected.signal].dir = vecY:rotated(data.newTransform.rot)
  instances[selected.signal].radius = clamp(data.newTransform.scl, 1, 100)
  instances[selected.signal].road = nil
  updateGizmoTransform()
end

local function createControllerActionUndo(data)
  elements[controllers[data.deleteIdx].id] = nil
  table.remove(controllers, data.deleteIdx or #controllers)
  selected.controller = math.max(1, selected.controller - 1)
  selectController(selected.controller)
end

local function createControllerActionRedo(data)
  table.insert(controllers, trafficSignals.newController())
  selected.controller = #controllers
  controllers[selected.controller]:onDeserialized(data)
  controllers[selected.controller].name = data.name or "Controller "..selected.controller
  elements[controllers[selected.controller].id] = controllers[selected.controller]
  selectController(selected.controller)
end

local function createSequenceActionUndo(data)
  elements[sequences[data.deleteIdx].id] = nil
  table.remove(sequences, data.deleteIdx or #sequences)
  selected.sequence = math.max(1, selected.sequence - 1)
  selectSequence(selected.sequence)
end

local function createSequenceActionRedo(data)
  table.insert(sequences, trafficSignals.newSequence())
  selected.sequence = #sequences
  sequences[selected.sequence]:onDeserialized(data)
  sequences[selected.sequence].name = data.name or "Sequence "..selected.sequence
  elements[sequences[selected.sequence].id] = sequences[selected.sequence]
  selectSequence(selected.sequence)
end

local function gizmoBeginDrag()
  if instances[selected.signal] then
    instances[selected.signal].rot = quatFromDir(instances[selected.signal].dir, vecUp)
    oldTransform.pos = vec3(instances[selected.signal].pos)
    oldTransform.rot = quat(instances[selected.signal].rot)
    oldTransform.scl = instances[selected.signal].radius
  end
end

local function gizmoEndDrag()
  if instances[selected.signal] then
    isDragging = false
    local newTransform = {
      pos = vec3(instances[selected.signal].pos),
      rot = quat(instances[selected.signal].rot),
      scl = instances[selected.signal].radius
    }

    local act = {oldTransform = oldTransform, newTransform = newTransform}
    editor.history:commitAction("Transform Signal Instance", act, transformInstanceActionUndo, transformInstanceActionRedo)
  end
end

local function gizmoMidDrag()
  if instances[selected.signal] then
    isDragging = true
    if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
      instances[selected.signal].pos:set(editor.getAxisGizmoTransform():getColumn(3))
    elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
      local rotation = QuatF(0, 0, 0, 1)
      rotation:setFromMatrix(editor.getAxisGizmoTransform())

      if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
        instances[selected.signal].rot = quat(rotation)
      else
        instances[selected.signal].rot = oldTransform.rot * quat(rotation)
      end
      instances[selected.signal].dir = vecY:rotated(instances[selected.signal].rot)
    elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
      local scl = vec3(editor.getAxisGizmoScale())
      local sclMin, sclMax = math.min(scl.x, scl.y, scl.z), math.max(scl.x, scl.y, scl.z)
      instances[selected.signal].radius = clamp(sclMin < 1 and oldTransform.scl * sclMin or oldTransform.scl * sclMax, 1, 100)
    end
  end
end

local function tabCtrlDefinitionTypes()
  if im.BeginCombo("Type##ctrlDefinitionTypes", signalCtrlDefinitions.typesSorted[selected.ctrlDefType] or "(None)") then
    for i, name in ipairs(signalCtrlDefinitions.typesSorted) do
      if im.Selectable1(name.."##ctrlDefinitionType", selected.ctrlDefType == i) then
        selected.ctrlDefType = i
        ctrlDefinitionTypeName = nil
      end
    end
    im.EndCombo()
  end
  if im.Button("New...##ctrlDefinitionTypes") then
    local name = "Type "..(#signalCtrlDefinitions.typesSorted + 1)
    selected.ctrlDefType = 0
    ctrlDefinitionTypeName = im.ArrayChar(256, name)
    signalCtrlDefinitions.types[name] = {name = name, states = {"basicStop"}}
    signalCtrlDefinitions._update = true
  end
  im.SameLine()
  if im.Button("Remove##ctrlDefinitionTypes") then
    signalCtrlDefinitions.types[signalCtrlDefinitions.typesSorted[selected.ctrlDefType] or ''] = nil
    selected.ctrlDefType = 0
    ctrlDefinitionTypeName = nil
    signalCtrlDefinitions._update = true
  end

  im.Dummy(dummyVec)
  local currName = signalCtrlDefinitions.typesSorted[selected.ctrlDefType] or ''
  local currData = signalCtrlDefinitions.types[currName]
  if currData then
    currData._edited = true
    if not ctrlDefinitionTypeName then
      ctrlDefinitionTypeName = im.ArrayChar(256, currName)
    end

    if editor.uiInputText("Name##ctrlDefinitionTypes", ctrlDefinitionTypeName, nil, im.InputTextFlags_EnterReturnsTrue) then
      local name = ffi.string(ctrlDefinitionTypeName)
      signalCtrlDefinitions.types[name] = signalCtrlDefinitions.types[currName]
      signalCtrlDefinitions.types[name].name = name
      signalCtrlDefinitions.types[currName] = nil
      ctrlDefinitionTypeName = nil
      selected.ctrlDefType = 0
      signalCtrlDefinitions._update = true
    end

    -- temp data for this window
    if not currData.statesArraySize then
      currData.statesArraySize = currData.states and #currData.states or 1
    end
    currData.defaultIndex = currData.defaultIndex or 1

    local var = im.IntPtr(currData.statesArraySize)
    im.PushItemWidth(100 * im.uiscale[0])
    if im.InputInt("States Array Size".."##ctrlDefinitionTypeData", var, 1) then
      currData.statesArraySize = clamp(var[0], 1, 20)
    end
    im.PopItemWidth()

    im.Dummy(dummyVec)

    local columnWidth = im.GetContentRegionAvailWidth() * 0.5

    im.Columns(2)
    im.SetColumnWidth(1, columnWidth)

    im.TextUnformatted("State")
    im.NextColumn()
    im.TextUnformatted("Is Default")
    im.NextColumn()

    for i = 1, currData.statesArraySize do
      if not currData.states[i] then
        table.insert(currData.states, "basicStop")
      end

      if im.BeginCombo("##ctrlDefinitionTypeDataState"..i, currData.states[i] or "(None)") then
        for _, state in ipairs(signalCtrlDefinitions.tempStatesSorted) do
          if im.Selectable1(state.."##ctrlDefinitionTypeData"..i, currData.states[i] == state) then
            currData.states[i] = state
          end
        end
        im.EndCombo()
      end
      im.NextColumn()

      local val = im.IntPtr(currData.defaultIndex)

      if im.RadioButton2("##ctrlDefinitionTypeDataDefaultState"..i, val, im.Int(i)) then
        currData.defaultIndex = val[0]
      end
      im.NextColumn()
    end
  end
  im.Columns(1)

  im.Dummy(dummyVec)
end

local function tabCtrlDefinitionStates()
  if im.BeginCombo("State##ctrlDefinitionStates", signalCtrlDefinitions.statesSorted[selected.ctrlDefState] or "(None)") then
    for i, name in ipairs(signalCtrlDefinitions.statesSorted) do
      if im.Selectable1(name.."##ctrlDefinitionState", selected.ctrlDefState == i) then
        selected.ctrlDefState = i
        ctrlDefinitionStateName = nil
      end
    end
    im.EndCombo()
  end
  if im.Button("New...##ctrlDefinitionStates") then
    local name = "State "..(#signalCtrlDefinitions.statesSorted + 1)
    selected.ctrlDefState = 0
    ctrlDefinitionStateName = im.ArrayChar(256, name)
    signalCtrlDefinitions.states[name] = {name = name, action = "stop", duration = 3, flashingInterval = 0, flashingLights = {}, enableFlashingLights = false, flashingLightsArraySize = 1, lightsArraySize = 3}
    signalCtrlDefinitions._update = true
  end
  im.SameLine()
  if im.Button("Remove##ctrlDefinitionStates") then
    signalCtrlDefinitions.states[signalCtrlDefinitions.statesSorted[selected.ctrlDefState] or ''] = nil
    selected.ctrlDefState = 0
    ctrlDefinitionStateName = nil
    signalCtrlDefinitions._update = true
  end

  im.Dummy(dummyVec)
  local currName = signalCtrlDefinitions.statesSorted[selected.ctrlDefState] or ''
  local currData = signalCtrlDefinitions.states[currName]
  if currData then
    currData._edited = true
    if not ctrlDefinitionStateName then
      ctrlDefinitionStateName = im.ArrayChar(256, currName)
    end

    -- temp data for this window
    if not currData.lightsArraySize then
      currData.lightsArraySize = currData.lights and #currData.lights or 3
    end
    if not currData.flashingLights then
      currData.flashingLights = {currData.lights and deepcopy(currData.lights) or {}}
    end
    if not currData.flashingLightsArraySize then
      currData.flashingLightsArraySize = #currData.flashingLights
      currData.enableFlashingLights = currData.flashingLightsArraySize > 1 and true or false
    end
    currData.duration = currData.duration or 0

    if editor.uiInputText("Name##ctrlDefinitionState", ctrlDefinitionStateName, nil, im.InputTextFlags_EnterReturnsTrue) then
      local name = ffi.string(ctrlDefinitionStateName)
      signalCtrlDefinitions.states[name] = signalCtrlDefinitions.states[currName]
      signalCtrlDefinitions.states[name].name = name
      signalCtrlDefinitions.states[currName] = nil
      ctrlDefinitionStateName = nil
      selected.ctrlDefState = 0
      signalCtrlDefinitions._update = true
    end

    im.PushItemWidth(itemWidth)
    if im.BeginCombo("Signal Action##ctrlDefinitionState", currData.action or "(None)") then
      for _, action in ipairs(tableKeysSorted(signalCtrlDefinitions.signalActions)) do
        if im.Selectable1(action.."##ctrlDefinitionState", currData.action == action) then
          currData.action = action
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()

    local var = im.IntPtr(currData.lightsArraySize)
    im.PushItemWidth(100 * im.uiscale[0])
    if im.InputInt("Lights Array Size".."##ctrlDefinitionStateLight", var, 1) then
      currData.lightsArraySize = clamp(var[0], 1, 5)
    end
    im.PopItemWidth()

    var = im.FloatPtr(currData.duration)
    im.PushItemWidth(100 * im.uiscale[0])
    if im.InputFloat("Default Duration##ctrlDefinitionStateLight", var, 0.1, 0.1, "%.2f", im.InputTextFlags_EnterReturnsTrue) then
      currData.duration = math.max(0, var[0])
    end
    im.PopItemWidth()
    im.tooltip("Set this to 0 to disable duration.")

    var = im.BoolPtr(currData.enableFlashingLights)
    if im.Checkbox("Enable Flashing Lights Sequence", var) then
      currData.enableFlashingLights = var[0]
    end

    if currData.enableFlashingLights then
      var = im.FloatPtr(currData.flashingInterval)
      im.PushItemWidth(100 * im.uiscale[0])
      if im.InputFloat("Flashing Lights Interval##ctrlDefinitionStateLight", var, 0.1, 0.1, "%.2f", im.InputTextFlags_EnterReturnsTrue) then
        currData.flashingInterval = math.max(0, var[0])
      end
      im.PopItemWidth()
      im.Dummy(dummyVec)

      if im.Button("Create##flashingLight") then
        currData.flashingLightsArraySize = currData.flashingLightsArraySize + 1
        selected.flashingLight = currData.flashingLightsArraySize
      end
      im.SameLine()
      if im.Button("Delete##sequencePhase") then
        currData.flashingLightsArraySize = math.max(1, currData.flashingLightsArraySize - 1)
        selected.flashingLight = math.min(selected.flashingLight, currData.flashingLightsArraySize)
      end

      for i = 1, currData.flashingLightsArraySize do
        local isCurrentLight = i == selected.flashingLight
        if isCurrentLight then
          im.PushStyleColor2(im.Col_Button, im.GetStyleColorVec4(im.Col_ButtonActive))
        end
        if im.Button(" "..i.." ") then
          selected.flashingLight = i
        end
        if isCurrentLight then
          im.PopStyleColor()
        end
        im.SameLine()
      end
      im.Dummy(dummyVec)

      im.TextUnformatted("Flashing Light #"..selected.flashingLight)
      im.Dummy(dummyVec)
    else
      selected.flashingLight = 1
    end

    for i = 1, currData.lightsArraySize do
      if not currData.flashingLights[selected.flashingLight] then
        currData.flashingLights[selected.flashingLight] = {}
      end
      if not currData.flashingLights[selected.flashingLight][i] then
        table.insert(currData.flashingLights[selected.flashingLight], "black")
      end

      im.PushItemWidth(itemWidth)
      if im.BeginCombo("Light Color #"..i.."##ctrlDefinitionStateLight"..i, currData.flashingLights[selected.flashingLight][i] or "(None)") then
        for _, color in ipairs(tableKeysSorted(signalCtrlDefinitions.signalColors)) do
          if im.Selectable1(color.."##ctrlDefinitionStateLight"..i, currData.flashingLights[selected.flashingLight][i] == color) then
            currData.flashingLights[selected.flashingLight][i] = color
          end
        end
        im.EndCombo()
      end
      im.PopItemWidth()
      im.SameLine()
      local iconColor = signalCtrlDefinitions.signalColors[currData.flashingLights[selected.flashingLight][i]]
      if iconColor then
        local c = iconColor:toTable()
        iconColor = im.ImVec4(c[1], c[2], c[3], c[4])
      else
        iconColor = im.ImVec4(1, 1, 1, 1)
      end
      editor.uiIconImage(editor.icons.lens, iconVec, iconColor)
    end
  end

  im.Dummy(dummyVec)
end

local function windowOverwrite()
  im.SetNextWindowPos(im.GetCursorScreenPos(), im.Cond_Always)
  im.SetNextWindowSize(im.ImVec2(300, 100), im.Cond_FirstUseEver)
  if im.Begin("Confirm##trafficSignals", windowFlags.overwrite, bit.bor(im.WindowFlags_NoDocking, im.WindowFlags_NoCollapse)) then
    im.TextUnformatted("Are you sure you want to clear signals data?")
    if im.Button("YES") then
      im.CloseCurrentPopup()
      windowFlags.overwrite[0] = false
      resetSignals()
    end
    im.SameLine()
    if im.Button("NO") then
      im.CloseCurrentPopup()
      windowFlags.overwrite[0] = false
    end
  end
  im.End()
end

local function windowInstanceGroups()
  im.SetNextWindowSize(im.ImVec2(400, 600), im.Cond_FirstUseEver)
  if im.Begin("Signal Groups##instanceGroups", windowFlags.instanceGroups) then
    if im.Button("Auto Set Groups") then -- automatically creates groups based on intersections (determined by algorithm)
      for _, instance in ipairs(instances) do
        instance.intersectionId = nil
      end
      for _, instance in ipairs(instances) do
        if not instance.group and not instance.intersectionId then
          local refPos = instance.pos + instance.dir * math.max(3, instance.radius)
          local idList = {}
          for _, other in ipairs(instances) do
            if not other.intersectionId and instance.sequenceId == other.sequenceId then
              if instance.pos:squaredDistance(other.pos) <= 1600 and other.dir:dot(refPos - other.pos) > 0 then
                table.insert(idList, other.id)
                other.intersectionId = instance.id
              end
            end
          end

          if idList[2] then
            local str = table.concat(idList, "_")
            str = "autoGroup"..str
            groups[str] = {}

            for _, id in ipairs(idList) do
              if not elements[id].group then
                elements[id].group = str
              end
            end
          end
        end
      end
      groupsSorted = tableKeysSorted(groups)
      groupsEdited = true
    end
    im.SameLine()
    if im.Button("Reset All") then --
      for _, instance in ipairs(instances) do
        instance.group = nil
      end
      groups = {}
      groupsSorted = {}
      groupsEdited = true
    end

    if not instanceGroupName then
      instanceGroupName = im.ArrayChar(256, "")
    end

    local width = im.GetContentRegionAvailWidth() * 0.5

    im.BeginChild1("instanceGroupsList", im.ImVec2(width, 550 * im.uiscale[0]), im.WindowFlags_ChildWindow)
    if not groupsSorted[1] then
      im.Selectable1("(No groups)##instanceGroup", false)
    end
    for i, group in ipairs(groupsSorted) do
      if im.Selectable1(group.."##instanceGroup", selected.group == i) then
        selected.group = i
      end
    end

    im.Separator()

    im.PushItemWidth(im.GetContentRegionAvailWidth() * 0.75)
    editor.uiInputText("##instanceGroupName", instanceGroupName)
    im.PopItemWidth()
    im.SameLine()

    if im.Button("Add##instanceGroupName") then
      local newGroup = ffi.string(instanceGroupName)
      if string.len(newGroup) > 0 then
        groups[newGroup] = {}
        groupsSorted = tableKeysSorted(groups)
        selected.group = arrayFindValueIndex(groupsSorted, newGroup) or 0
        instanceGroupName = nil
        groupsEdited = true
      end
    end
    im.tooltip("Create a new signal group with this name.")

    im.EndChild()
    im.SameLine()

    im.BeginChild1("instanceGroupsSelections", im.ImVec2(0, 550 * im.uiscale[0]), im.WindowFlags_ChildWindow)
    local currGroup = groupsSorted[selected.group]
    for _, instance in ipairs(instances) do
      if instance.group and instance.group ~= currGroup then
        im.BeginDisabled()
      end
      local selected = instance.group == currGroup
      if not currGroup then
        selected = false
      end

      if selected then
        local instancePosUp = instance.pos + vec3(0, 0, 1000)
        debugDrawer:drawCylinder(instance.pos, instancePosUp, cylinderRadius, debugColors.selected)
      end

      im.PushStyleColor2(im.Col_Header, im.GetStyleColorVec4(im.Col_ButtonActive))
      if im.Selectable1(instance.name.."##instanceOfGroup", selected) and currGroup then
        if instance.group then
          instance.group = nil
        else
          instance.group = currGroup
          selectInstance(instance._idx)
        end

        groupsEdited = true
      end
      im.PopStyleColor()

      if instance.group and instance.group ~= currGroup then
        im.EndDisabled()
      end
    end

    im.EndChild()

    if im.Button("Close##instanceGroups") then
      windowFlags.instanceGroups[0] = false
      if groupsEdited then
        updateGroups()
        groupsEdited = false
      end
      log("I", logTag, "Instance groups updated")
    end

    im.End()
  end
end

local function windowSignalCtrlDefinitions()
  im.SetNextWindowSize(im.ImVec2(500, 600), im.Cond_FirstUseEver)
  if im.Begin("Controller Definitions##ctrlDefinitions", windowFlags.instanceGroups) then
    if not signalCtrlDefinitions then
      core_trafficSignals.loadControllerDefinitions()
      signalCtrlDefinitions = deepcopy(core_trafficSignals.getControllerDefinitions())
      signalCtrlDefinitions.origStates = deepcopy(signalCtrlDefinitions.states)

      table.clear(signalCtrlDefinitions.states)
      table.clear(signalCtrlDefinitions.types)
      tableMerge(signalCtrlDefinitions, jsonReadFile(editor.levelPath.."signalControllerDefinitions.json") or {}) -- loads only custom data
      signalCtrlDefinitions._update = true
    end

    if signalCtrlDefinitions._update then
      signalCtrlDefinitions.statesSorted = tableKeysSorted(signalCtrlDefinitions.states)
      signalCtrlDefinitions.typesSorted = tableKeysSorted(signalCtrlDefinitions.types)

      local tempStates = tableMerge(signalCtrlDefinitions.origStates, signalCtrlDefinitions.states)
      signalCtrlDefinitions.tempStatesSorted = tableKeysSorted(tempStates)

      if selected.ctrlDefState == 0 then
        if ctrlDefinitionStateName then
          selected.ctrlDefState = arrayFindValueIndex(signalCtrlDefinitions.statesSorted, ffi.string(ctrlDefinitionStateName)) or 1
        else
          selected.ctrlDefState = 1
        end
      end
      if selected.ctrlDefType == 0 then
        if ctrlDefinitionTypeName then
          selected.ctrlDefType = arrayFindValueIndex(signalCtrlDefinitions.typesSorted, ffi.string(ctrlDefinitionTypeName)) or 1
        else
          selected.ctrlDefType = 1
        end
      end
      signalCtrlDefinitions._update = nil
    end

    if im.BeginTabBar("Controller Definition Tabs##ctrlDefinitions") then
      if im.BeginTabItem("Types") then
        tabCtrlDefinitionTypes()
        im.EndTabItem()
      end
      if im.BeginTabItem("States") then
        tabCtrlDefinitionStates()
        im.EndTabItem()
      end
    end

    im.Separator()

    if im.Button("Save & Close##ctrlDefinitions") then
      for _, typeData in pairs(signalCtrlDefinitions.types) do
        if typeData.statesArraySize then
          if typeData.statesArraySize == 1 or typeData.defaultIndex > typeData.statesArraySize then
            typeData.defaultIndex = nil
          end
          for i = #typeData.states, typeData.statesArraySize + 1, -1 do
            table.remove(typeData.states, i)
          end
        end

        typeData.statesArraySize = nil
        typeData._edited = nil
      end

      for _, state in pairs(signalCtrlDefinitions.states) do
        if state._edited then
          for i = #state.flashingLights, state.flashingLightsArraySize + 1, -1 do
            table.remove(state.flashingLights, i)
          end
          for i, light in ipairs(state.flashingLights) do
            for j = #light, state.lightsArraySize + 1, -1 do
              table.remove(state.flashingLights[i], j)
            end
          end

          state.lights = deepcopy(state.flashingLights[1] or {})

          if not state.enableFlashingLights then
            state.flashingLights = nil
            state.flashingInterval = 0
          end

          if state.duration <= 0 then
            state.duration = nil
          end

          state.enableFlashingLights = nil
          state.flashingLightsArraySize = nil
          state.lightsArraySize = nil
        end
        state._edited = nil
      end

      local saveData = {states = signalCtrlDefinitions.states, types = signalCtrlDefinitions.types}
      jsonWriteFile(editor.levelPath.."signalControllerDefinitions.json", saveData, true)
      core_trafficSignals.resetControllerDefinitions()
      core_trafficSignals.setControllerDefinitions(saveData)
      windowFlags.ctrlDefinitions[0] = false
      log("I", logTag, "Custom signal controller data saved")
    end
    im.SameLine()
    if im.Button("Discard & Close##ctrlDefinitions") then
      windowFlags.ctrlDefinitions[0] = false
    end
    im.End()
  end
end

local function tabInstances()
  im.BeginChild1("instances", im.ImVec2(200 * im.uiscale[0], 0), im.WindowFlags_ChildWindow)

  if im.CollapsingHeader1("(Ungrouped)##instanceDefaultGroup", im.TreeNodeFlags_DefaultOpen) then
    for _, instance in ipairs(instances) do
      if not instance.group then
        if im.Selectable1(instance.name, instance._idx == selected.signal) then
          selectInstance(instance._idx)
        end
      end
    end
  end

  for _, group in ipairs(groupsSorted) do
    if im.CollapsingHeader1(group.."##instanceGroup", im.TreeNodeFlags_DefaultOpen) then
      for _, id in ipairs(groups[group]) do
        local elem = elements[id]
        if im.Selectable1(elem.name, elem._idx == selected.signal) then
          selectInstance(elem._idx)
        end
      end
    end
  end

  im.Separator()

  im.Selectable1("New...##instance", false)
  im.tooltip("Shift-Click in the world to create a new signal instance point.")

  if im.Selectable1("Groups...##instance") then
    windowFlags.instanceGroups[0] = true
  end
  im.tooltip("Organize signal instances into groups.")

  im.EndChild()
  im.SameLine()

  im.BeginChild1("instanceData", im.ImVec2(0, 0), im.WindowFlags_ChildWindow)
  itemWidth = im.GetContentRegionAvailWidth() * 0.5
  if not im.IsWindowHovered(im.HoveredFlags_AnyWindow) and not signalObjectFlags.selectObjects and editor.keyModifiers.shift and mousePos then
    debugDrawer:drawTextAdvanced(mousePos, "Create Signal Instance", ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 255))

    if im.IsMouseClicked(0) then
      local act = {pos = mousePos, controllerId = lastUsed.controllerId, sequenceId = lastUsed.sequenceId}
      editor.history:commitAction("Create Signal Instance", act, createInstanceActionUndo, createInstanceActionRedo)
      selectInstance(selected.signal)
    end
  end

  local currInstance = instances[selected.signal]
  if currInstance then
    im.TextUnformatted("Current Signal: "..currInstance.name.." ["..currInstance.id.."]")
    im.SameLine()
    if im.Button("Delete##instance") then
      local act = instances[selected.signal]:onSerialize()
      act.deleteIdx = selected.signal
      editor.history:commitAction("Delete Signal Instance", act, createInstanceActionRedo, createInstanceActionUndo)
    end

    im.TextUnformatted("Current Group: "..(currInstance.group or "(None)"))

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
      instances[selected.signal].pos = vec3(signalPos[0], signalPos[1], signalPos[2])
      gizmoEndDrag()
    end

    im.Dummy(dummyVec)

    ---- select sequence for signal instance ----
    local elem = elements[currInstance.sequenceId]
    local name = elem and elem.name or "(Missing)"
    if currInstance.sequenceId == 0 then
      name = "Basic" -- this is a nil sequence
    end

    im.PushItemWidth(itemWidth)
    if im.BeginCombo("Sequence##instance", name) then
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
      if not elements[currInstance.sequenceId] then
        im.SameLine()
        editor.uiIconImage(editor.icons.error_outline, iconVec, colorError)
      end

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

    im.Dummy(dummyVec)

    ---- select controller for signal instance ----
    elem = elements[currInstance.controllerId]
    name = elem and elem.name or "(Missing)"
    if currInstance.controllerId == 0 then
      name = "(None)"
    end

    im.PushItemWidth(itemWidth)
    if im.BeginCombo("Controller##instance", name) then
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
      if not elements[currInstance.controllerId] then
        im.SameLine()
        editor.uiIconImage(editor.icons.error_outline, iconVec, colorError)
      end

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

    im.SameLine()
    im.Button("?")
    im.tooltip("Select signal objects in the level to link with this instance. Remember to Save Level (Ctrl+S) after you are done.")

    if timedTexts.applyFields then
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
          for _, objId in ipairs(editor.selection.object) do
            currInstance:assignSignalObject(objId)
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
    if im.Selectable1(ctrl.name, selected.controller == i) then
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
  local currController = controllers[selected.controller]
  if currController then
    im.TextUnformatted("Current Controller: "..currController.name.." ["..currController.id.."]")

    im.SameLine()
    if im.Button("Delete##controller") then
      local act = currController:onSerialize()
      act.deleteIdx = selected.controller
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

    if im.Button("Manage Custom Controllers...##controller") then
      windowFlags.ctrlDefinitions[0] = true
    end

    im.Dummy(dummyVec)
    im.Separator()
    im.TextUnformatted("States")

    im.SameLine()
    im.Button("?")
    im.tooltip("States run in order; the next state starts when the timer reaches the current state duration.")

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
      local columnWidth = im.GetContentRegionAvailWidth() * 0.333

      im.Columns(3)
      im.SetColumnWidth(0, columnWidth)
      im.SetColumnWidth(1, columnWidth)

      im.TextUnformatted("State Name")
      im.NextColumn()
      im.TextUnformatted("Duration")
      im.NextColumn()
      im.TextUnformatted("Is Infinite")
      im.NextColumn()

      for i, state in ipairs(currController.states) do
        local stateData = currController:getStateData(state.state)
        if stateData then
          im.TextUnformatted(stateData.name)
          im.NextColumn()

          state.duration = state.duration or -1

          local var = im.FloatPtr(state.duration)
          im.PushItemWidth(columnWidth - 10)
          if im.InputFloat("##controllerState"..i, var, 0.1, 0.1, "%.2f", im.InputTextFlags_EnterReturnsTrue) then
            state.duration = math.max(0, var[0])
          end
          im.PopItemWidth()
          if state.state == "redTrafficLight" then
            im.tooltip("This is usually the delay time until the next signal phase starts.")
          end
          im.NextColumn()

          var = im.BoolPtr(state.duration == -1)
          if im.Checkbox("##controllerStateInfinite"..i, var) then
            state.duration = var[0] and -1 or 0
          end
          im.NextColumn()
        end
      end

      im.Columns(1)
    end
  end
  im.EndChild()
end

local function tabSequences()
  table.clear(selectableControllers)

  im.BeginChild1("sequences", im.ImVec2(150 * im.uiscale[0], 0), im.WindowFlags_ChildWindow)

  for i, sequence in ipairs(sequences) do
    if im.Selectable1(sequence.name, selected.sequence == i) then
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
  local currSequence = sequences[selected.sequence]
  if currSequence then
    im.TextUnformatted("Current Sequence: "..currSequence.name.." ["..currSequence.id.."]")

    im.SameLine()
    if im.Button("Delete##sequence") then
      local act = currSequence:onSerialize()
      act.deleteIdx = selected.sequence
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

    im.SameLine()
    im.Button("?")
    im.tooltip("Phases manage the order / grouping of controllers. For best results, avoid duplicate controllers across all phases.")

    im.Dummy(dummyVec)

    if im.Button("Create##sequencePhase") then
      currSequence:createPhase()
      selected.phase = #currSequence.phases
    end
    im.SameLine()
    if im.Button("Delete##sequencePhase") then
      currSequence:deletePhase()
      if not currSequence.phases[selected.phase] then
        selected.phase = math.max(1, #currSequence.phases)
      end
    end

    for i, phase in ipairs(currSequence.phases) do
      local isCurrentPhase = i == selected.phase
      if isCurrentPhase then
        im.PushStyleColor2(im.Col_Button, im.GetStyleColorVec4(im.Col_ButtonActive))
      end
      if im.Button(" "..i.." ") then
        selected.phase = i
      end
      if isCurrentPhase then
        im.PopStyleColor()
      end
      im.SameLine()
    end
    im.Dummy(dummyVec)

    local phase = currSequence.phases[selected.phase]
    if phase then
      im.TextUnformatted("Phase #"..selected.phase)

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

      local columnWidth = im.GetContentRegionAvailWidth() * 0.5

      im.Columns(2)
      im.SetColumnWidth(1, columnWidth)

      im.TextUnformatted("Controller Name")
      im.NextColumn()
      im.TextUnformatted("Is Required")
      im.SameLine()
      im.Button("?")
      im.tooltip("The sequence phase will advance when all of the required controller cycles are completed.")
      im.NextColumn()

      local controllersDict = {}
      for _, cd in ipairs(phase.controllerData) do
        controllersDict[cd.id] = 1
      end

      for i, cd in ipairs(phase.controllerData) do
        if im.BeginCombo("##phaseControllerName"..i, elements[cd.id] and elements[cd.id].name or "(None)") then
          for _, ctrl in ipairs(controllers) do
            if not controllersDict[ctrl.id] and im.Selectable1(ctrl.name, cd.id == ctrl.id) then -- prevents duplicates by limiting controller selection
              cd.id = ctrl.id
            end
          end
          im.EndCombo()
        end
        im.NextColumn()

        var = im.BoolPtr(cd.required)
        if im.Checkbox("##phaseControllerRequired"..i, var) then
          cd.required = var[0]
        end
        im.NextColumn()
      end

      im.Columns(1)
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

      local columnWidth = im.GetContentRegionAvailWidth() * 0.25
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
        local r, g, b = HSVtoRGB((sequence.currStep - 1) / (#sequence.sequenceTimings), 1, 0.6)

        im.PushStyleColor2(im.Col_PlotHistogram, im.ImVec4(r, g, b, 1))
        im.ProgressBar(currTime / maxTime, im.ImVec2(im.GetContentRegionAvailWidth(), 0))
        im.PopStyleColor()

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
    local alpha = selected.signal == i and 1 or 0.5
    local camDist = instance.pos:squaredDistance(core_camera.getPosition())
    if camDist <= square(editor.getPreference("gizmos.visualization.visualizationDrawDistance")) or selected.signal == i then
      local str = instance.name
      local strColor = ColorF(1, 1, 1, alpha)
      if options.displayNameMode == 2 then
        str = elements[instance.controllerId] and elements[instance.controllerId].name or "(Null controller)"
        strColor = ColorF(0, 1, 0, alpha)
      elseif options.displayNameMode == 3 then
        str = elements[instance.sequenceId] and elements[instance.sequenceId].name or "(Null sequence)"
        strColor = ColorF(0, 1, 1, alpha)
      end

      local shapeColor = selected.signal == i and debugColors.selected or debugColors.main

      if selected.signal == i and instance.road then
        shapeColor = debugColors.selected
      end

      if selected.signal == i then
        debugDrawer:drawSphere(instance.pos, cylinderRadius * 2, debugColors.main)
        if isDragging then
          debugDrawer:drawSphere(instance.pos, instance.radius, ColorF(1, 1, 1, 0.1))
        end

        if options.showClosestRoad and instance.road and instance.road.n1 then
          debugDrawer:drawSphere(mapNodes[instance.road.n1].pos, cylinderRadius, debugColors.main)
          debugDrawer:drawSphere(mapNodes[instance.road.n2].pos, cylinderRadius, debugColors.main)
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

      selectInstance(selected.signal)
      selectController(selected.controller)
      selectSequence(selected.sequence)

      updateGroups()

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
        windowFlags.overwrite[0] = true
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

    if im.BeginMenu("Tools") then
      if im.MenuItem1("Check Signal Errors") then
        local errCount = 0
        for _, instance in ipairs(instances) do
          if instance.controllerId > 0 and not elements[instance.controllerId] then
            errCount = errCount + 1
          end
          if instance.sequenceId > 0 and not elements[instance.sequenceId] then
            errCount = errCount + 1
          end
        end

        if errCount == 0 then
          timedTexts.signalsValid = {"Signals validated!", 3}
          timedTexts.signalsInvalid = nil
        else
          timedTexts.signalsInvalid = {"Signal errors: "..errCount, 12}
          timedTexts.signalsValid = nil
        end
      end

      im.EndMenu()
    end

    if timedTexts.save then
      im.SameLine()
      im.TextColored(colorWarning, timedTexts.save[1])
    end
    if timedTexts.signalsValid then
      im.SameLine()
      im.TextColored(colorWarning, timedTexts.signalsValid[1])
    end
    if timedTexts.signalsInvalid then
      im.SameLine()
      im.TextColored(colorError, timedTexts.signalsInvalid[1])
    end
    im.EndMenuBar()

    if windowFlags.overwrite[0] then
      windowOverwrite()
    end

    if windowFlags.instanceGroups[0] then
      windowInstanceGroups()
    end

    if windowFlags.ctrlDefinitions[0] then
      windowSignalCtrlDefinitions()
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