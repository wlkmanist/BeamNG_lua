-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

require("utils")
local json = require("json")
local M = {}
M.dependencies = { "core_input_actions", "core_input_categories", "core_multiseat", "license", "core_versionUpdate" }
M.isMenuActive = false
M.autoAssignPlayersToDevices = true
M.devices = {}
M.bindings = {}
M.defaultBindings = {}
M.assignedPlayers = {}
local actionToControl = nil
local usedBindingFiles = nil -- nil = not tracking
local recentDevices

local function trDeviceMessage(key, productName)
  return core_locales.contextTranslate(key, {
    productName = core_locales.translate(productName, productName),
  })
end

local function fillNormalizeBindingDefaults(binding)
  local binding = deepcopy(binding)
  binding.filterType = tonumber(binding.filterType)
  binding.lockType = tonumber(binding.lockType)
  if binding.ffb then
    binding.ffb.updateType = tonumber(binding.ffb.updateType)
    binding.ffb.frequency = tonumber(binding.ffb.frequency)
  end
  -- populate any possible missing binding parameter with sensible default values, and upgrade old bindings
  binding.isLinear = nil -- remove deprecated field
  binding.scale  = nil -- remove deprecated field
  binding.isRanged = nil -- remove deprecated field
  if binding.deadzone      == nil then binding.deadzone = { ["end"] = 0 } end
  binding.deadzone.begin = nil -- remove deprecated field
  if binding.deadzone["end"] then binding.deadzone["end"] = tonumber(binding.deadzone["end"]) end
  if binding.deadzone["end"] and not binding.deadzoneResting then binding.deadzoneResting = binding.deadzone["end"] end
  if binding.deadzoneResting then binding.deadzoneResting = tonumber(binding.deadzoneResting) end
  if binding.deadzoneEnd   then binding.deadzoneEnd   = tonumber(binding.deadzoneEnd)   end
  binding.deadzone = nil -- remove deprecated field
  if binding.deadzoneResting == nil then binding.deadzoneResting = 0 end
  if binding.deadzoneEnd   == nil then binding.deadzoneEnd = 0 end
  if binding.control       ~= nil then binding.control = string.lower(binding.control) end
  if binding.linearity     == nil then binding.linearity = 1 end
  if binding.isInverted    == nil then binding.isInverted = false end
  if binding.isForceEnabled  == nil then binding.isForceEnabled = false end
  if binding.isForceInverted == nil then binding.isForceInverted = false end
  if binding.useLogitechSDK == nil then binding.useLogitechSDK = false end
  if binding.logitechVibrotactileCoef == nil then binding.logitechVibrotactileCoef = 1 end
  binding.logitechVibrotactileFreqMaxUIRangeMin = 20
  binding.logitechVibrotactileFreqMaxUIRangeMax = 150
  binding.logitechVibrotactileFreqMax = clamp(binding.logitechVibrotactileFreqMax or 50, binding.logitechVibrotactileFreqMaxUIRangeMin, binding.logitechVibrotactileFreqMaxUIRangeMax)
  if binding.ffb           == nil then binding.ffb = {} end
  if binding.ffb.forceCoef == nil then binding.ffb.forceCoef = 100 end
  if binding.ffb.smoothing == nil then binding.ffb.smoothing = 150 end
  if binding.ffb.updateType== nil then binding.ffb.updateType = 0 end
  if binding.ffb.isVibrationEnabled == nil then binding.ffb.isVibrationEnabled = false end
  if binding.ffb.enableThrottleForceFeedback == nil then binding.ffb.enableThrottleForceFeedback = true end
  if binding.ffb.enableBrakeForceFeedback == nil then binding.ffb.enableBrakeForceFeedback = true end
  if binding.ffb.deviceLightingMode == nil then binding.ffb.deviceLightingMode = "default" end
  if binding.ffbUpdateType ~= nil then binding.ffb.updateType = binding.ffbUpdateType end
  binding.ffbUpdateType = nil -- remove deprecated field (moved inside 'binding.ffb' by now)
  binding.ffb.smoothingHF = nil -- remove deprecated field
  if binding.ffb.forceLimit then binding.ffb.forceCoef = (binding.ffb.forceCoef * binding.ffb.forceLimit) / 10 end -- downscale forceCoef proportionally to the removal of forceLimit (which will bump it from whichever current value, up to "10")
  binding.ffb.forceLimit = nil -- remove deprecated field
  if binding.ffb.frequency   == nil then binding.ffb.frequency = 0 end
  if binding.ffb.gforceCoef  == nil then binding.ffb.gforceCoef = 0 end
  if binding.ffb.responseCurve==nil then binding.ffb.responseCurve = { {0, 0}, {1, 1} } end
  if binding.ffb.responseCorrected==nil then binding.ffb.responseCorrected = false end
  if binding.ffb.lowspeedCoef== nil then binding.ffb.lowspeedCoef = true end
  if binding.ffb.softlockEnabled == true then binding.ffb.softlockForce = 0.5 end
  if binding.ffb.softlockEnabled == false then binding.ffb.softlockForce = 0 end
  binding.ffb.smoothing2automatic = nil -- remove deprecated field (always automatically calculated)
  binding.ffb.smoothing2 = nil -- remove deprecated field (always automatically calculated)
  binding.ffb.softlockEnabled = nil
  if binding.ffb.softlockForce == nil then binding.ffb.softlockForce = 0.5 end
  binding.ffb.softlockForce = clamp(binding.ffb.softlockForce, 0, 1)
  binding.ffb.forceCoefLowSpeed = nil -- remove deprecated field
  if binding.filterType    == nil then binding.filterType = -1 end
  if binding.angle       == nil then binding.angle = 0 end
  if binding.lockType    == nil then binding.lockType = 3 end
  return binding
end

local defaultBinding = fillNormalizeBindingDefaults({})

-- From: https://web.archive.org/web/20131225070434/http://snippets.luacode.org/snippets/Deep_Comparison_of_Two_Values_3
-- available under MIT/X11
local function deepcompare(t1,t2)
  local ty1 = type(t1)
  local ty2 = type(t2)
  if ty1 ~= ty2 then return false end
  -- non-table types can be directly compared
  if ty1 ~= 'table' then return t1 == t2 end

  local testedKeys = {}
  for k1, v1 in pairs(t1) do
    local v2 = t2[k1]
    if v2 == nil or not deepcompare(v1, v2) then return false end
    testedKeys[k1] = true
  end
  for k2, v2 in pairs(t2) do
    if not testedKeys[k2] then
      local v1 = t1[k2]
      if v1 == nil or not deepcompare(v1, v2) then return false end
    end
  end
  return true
end

local function cleanBindingDefaults(binding)
  -- strip the binding settings that are default (leaving only the custom settings)
  local result = deepcopy(binding)
  for k, v in pairs(defaultBinding) do
    if deepcompare(result[k],v) then
      result[k] = nil
    end
  end
  return result
end

local function dumpbinding(binding)
  if binding == nil then return dumps(binding) end
  return dumps(cleanBindingDefaults(deepcopy(binding))):gsub("\n", " "):gsub(" +", " ")
end

local function sendBindingsToGE(devname, bindings, player)
  -- upload the provided bindings data into torque3d, associated with a specific device name
  if bindings == nil then
    log('E', 'bindings', "Error parsing bindings for device "..devname..": bindings is nil")
    return false
  end
  local count = 0
  for i,binding in pairs(bindings) do
    if binding.unused then
      goto continue
    end
    local action = core_input_actions.upgradeAction(binding.action)
    if not action then
      log('E', 'bindings', "Skipping invalid 'action' field on binding "..i.." in device "..devname..": "..dumpbinding(binding))
      goto continue
    end

    local success, actionMap, actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, isRelative, ctx, isCentered = core_input_actions.actionToCommands(action)
    if not success then
      log('E', 'bindings', "Couldn't load action "..action)
      goto continue
    end

    local b = fillNormalizeBindingDefaults(binding)
    b.action = action

    actionMap = actionMap.."ActionMap"
    local am = scenetree.findObject(actionMap)
    am:bind(devname, b.action, b.control, isCentered, b.deadzoneResting, b.deadzoneEnd, b.linearity, b.angle, b.lockType, b.isInverted, b.isForceEnabled, b.isForceInverted, b.useLogitechSDK, b.logitechVibrotactileCoef, b.logitechVibrotactileFreqMax, b.ffb.updateType, jsonEncode(b.ffb), actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, b.filterType, isRelative, player, ctx)
    count = count + 1
    ::continue::
  end
  log('D', 'bindings', "Loaded "..count.." bindings for device "..devname)
  return true
end
local function readBindingsFromDisk(paths, vehicleName, ignoreRemoved)
  local result = { bindings = {}, removed = {} }
  for _,path in ipairs(paths) do
    -- read and normalize/upgrade bindings from a single file on disk
    local fileData
    local f = readFile(path)
    if f then
      local success
      success, fileData = pcall(json.decode, f)
      if not success then
        log('E', 'bindings', "Error decoding json content from file "..dumps(path)..": "..dumps(fileData))
        fileData = nil
      end
      if usedBindingFiles then
        table.insert(usedBindingFiles, path)
      end
    else
      log('E', 'bindings', "Error parsing bindings in file "..path..": cannot open file")
    end
    for k,v in pairs(fileData or {}) do
      if k == "bindings" then
        for i, b in ipairs(v) do
          if b.control == nil then
            log('E', 'bindings', "Missing 'control' field on binding "..i.." in file "..path..": "..dumpbinding(b))
            goto nextBinding
          end
          b = fillNormalizeBindingDefaults(b)
          local action = core_input_actions.nameToUniqueName(b.action, vehicleName) -- this name-mangling is needed to prevent collisions with other vehicles' action names
          action = core_input_actions.upgradeAction(action)
          if not action then
            log('D', 'bindings', "Skipping invalid 'action' field on binding "..i.." in file "..path..": "..dumpbinding(b))
            goto nextBinding
          end
          b.action = action
          table.insert(result.bindings, b)
          ::nextBinding::
        end
      elseif  k == "removed" then
        for i, b in ipairs(v) do
          if ignoreRemoved then
            log('E', 'bindings', "Ignoring 'removed' binding in file "..dumps(path).." that shouldn't contain any 'removed' binding: "..dumpbinding(b))
            goto nextRemoved
          end
          if b.control == nil then
            log('E', 'bindings', "Missing 'control' field on removed binding "..i.." in file "..path..": "..dumpbinding(b))
            goto nextRemoved
          end
          local action = core_input_actions.nameToUniqueName(b.action, vehicleName) -- this name-mangling is needed to prevent collisions with other vehicles' action names
          action = core_input_actions.upgradeAction(action)
          if not action then
            log('D', 'bindings', "Skipping invalid 'action' field on removed binding "..i.." in file "..path..": "..dumpbinding(b))
            goto nextRemoved
          end
          b.action = action
          table.insert(result.removed, b)
          ::nextRemoved::
        end
      else
        if result[k] and (result[k] ~= v) then
          log("W", "", "Overwriting inputmap field "..dumps(k)..": "..dumps(result[k]).." --> "..dumps(v).." (new value read from "..dumps(path)..")")
        end
        result[k] = v
      end
    end
  end
  return result
end

local function bindingListToDict(list)
  -- convert from a binding list, to a dictionary with control\0action as keys
  local result = {}
  if list == nil then return result end
  for _,v in pairs(list) do
    if v.action  == nil then log("W", "bindings", "Binding is missing the 'action' field: " ..dumpbinding(v)) end
    if v.control == nil then log("W", "bindings", "Binding is missing the 'control' field: "..dumpbinding(v)) end
    if v.action and v.control then
      if result[v.control.."\0"..v.action] then
        log("W", "", "Found duplicate binding. The last seen binding will override earlier bindings: "..dumps(v.control, v.action))
      end
      result[v.control.."\0"..v.action] = cleanBindingDefaults(v)
    end
  end
  return result
end

local function createBindingsDiff(old, new)
  -- create an empty diff, populate it with non-bindings information (guid, devtype, productname, etc)
  local result = { bindings = {}, removed = {}, version = 1 }
  for k,v in pairs(old) do
    if k ~= "bindings" and k ~= "removed" then result[k] = v end
  end

  -- duplicate provided bindings as dicts (to leave originals untouched, and for easier processing)
  local dictOld = bindingListToDict(old.bindings)
  local dictNew = bindingListToDict(new.bindings)

  -- mark bindings that are to be removed
  local markedForRemoval = {}
  for k,v in pairs(dictOld) do
    if dictNew[k] == nil then
      markedForRemoval[k] = v
    end
  end

  -- process removed bindings
  for k,v in pairs(markedForRemoval) do
    log('D', 'bindings', "Removed binding (added to list): "..dumps(v.control).." : "..dumps(v.action))
    table.insert(result.removed, { control = v.control, action = v.action } )
    dictOld[k] = nil
  end

  -- process modified/new bindings
  for k,v in pairs(dictNew) do
    if dumps(dictOld[k]) ~= dumps(v) then
      if dictOld[k] then log('D', 'bindings', "Modified binding (added to list): "..dumps(v.control).." : "..dumps(v.action))
      else           log('D', 'bindings',    "New binding (added to list): "..dumps(v.control).." : "..dumps(v.action)) end
      table.insert(result.bindings, cleanBindingDefaults(v) )
    end
  end
  -- remove empty lists
  if tableIsEmpty(result.removed) then result.removed  = nil end
  if tableIsEmpty(result.bindings) then result.bindings = nil end
  if result.bindings == nil and result.removed == nil then result = nil end

  return result
end

local function applyResponseCurve(contents, path, curveInverted)
  for i,binding in pairs(contents.bindings) do
    if binding.ffb and binding.ffb.responseCorrected then
      local f = readFile(path)
      if not f then
        log('E', 'bindings', "Error parsing response curve in file "..path..": cannot open file")
        return contents
      end
      local xcolumn = nil
      local ycolumn = nil
      local responseCurve = {}
      for line in f:gmatch("([^\n\r]*)") do
        if line ~= "" then
          local x = nil
          local y = nil
          local column = 0
          for field in line:gmatch("([^,|]*)") do
            field = field:match("^%s*(.-)%s*$")
            if field ~= "" then
              local v = tonumber(field)
              if v then
                if xcolumn == nil or ycolumn == nil then
                  log("W", "", "Cannot recognize column headers in FFB response curve file: "..dumps(path))
                  if xcolumn == nil then
                    log("W", "", "Assuming X column is at: "..dumps(column))
                    xcolumn = column
                  else
                    if ycolumn == nil then
                    log("W", "", "Assuming Y column is at: "..dumps(column))
                    ycolumn = column
                    end
                  end
                end
                if column == xcolumn then x = v end
                if column == ycolumn then y = v end
              else
                if field == "force"     then xcolumn = column end
                if field == "LinearForce" then xcolumn = column end
                if field == "deltaX"          then ycolumn = column end
                if field == "Linear Force Response" then ycolumn = column end
              end
            end
            column = column + 1
          end
          if x ~= nil and y ~= nil then
            table.insert(responseCurve, {x, y})
            --log("I", "", dumps({x,y}))
          else
            log("D", "bindings", "Skipping invalid datapoint line in FFB response curve file: \""..line.."\"")
          end
        end
      end
      if curveInverted then
        log("D", "", "Inverting curve path: "..dumps(path))
        for n,v in ipairs(responseCurve) do
        v[2], v[1] = v[1], v[2]
        end
      end
      --log("I", "", "Response curve: "..dumps(responseCurve))
      binding.ffb.responseCurve = responseCurve
    end
  end
  return contents
end

local function applyInputmapDiff(base, diff)
  -- 1) handle 'bindings' + 'removed' fields
  local version = diff.version or base.version or 0
  local dictBase         = bindingListToDict(base.bindings)
  local dictDiffReplaced = bindingListToDict(diff.bindings)
  local dictDiffRemoved  = bindingListToDict(diff.removed )

  -- upgrade old diff format that had no support for duplicate bindings
  local allowDuplicates = version >= 1
  if not allowDuplicates then
    for k,v in pairs(dictDiffReplaced) do
      for kk,vv in pairs(dictBase) do
        if vv.control == v.control then
          log("I", "bindings", "Upgrading inputmap from old v0 format - Removing duplicate binding: "..dumps(v.control).." : "..dumps(v.action))
          dictDiffRemoved[kk] = vv
        end
      end
    end
  end

  -- merge removed bindings
  for k,v in pairs(dictDiffRemoved) do
    if dictBase[k] == nil then
      log("D", "bindings", "Merge: trying to remove a binding that is not there anymore: "..dumps(v))
    end
    dictBase[k] = nil
  end

  -- merge new/modified bindings
  for k,v in pairs(dictDiffReplaced) do
    dictBase[k] = v
  end

  -- convert back to list
  local bindings = {}
  for _,v in pairs(dictBase) do table.insert(bindings, cleanBindingDefaults(v)) end

  -- 2) handle the rest of fields
  local result = deepcopy(base)
  tableMerge(result, deepcopy(diff))
  result.removed = nil
  result.bindings = bindings

  -- return final composed result
  return result
end

local function getWritingDir(vehicleName)
  if vehicleName then return "settings/inputmaps/"..vehicleName
  else          return "settings/inputmaps" end
end

local function getWritingPath(vehicleName, devicetype, pidvid)
  -- find out the most appropriate path to write an inputmap file
  local basedir = getWritingDir(vehicleName)
  if devicetype == "mouse" or devicetype == "keyboard" then
    return basedir.."/" .. devicetype .. ".diff"
  end
  return basedir.."/" .. pidvid:lower() .. ".diff"
end

local function getDeviceInfo(device)
  local guid = Input.getProductGUID(device)
  local productName = Input.getProductName(device)
  local pidvid = Input.getVendorIDProductID(device)
  local playerNumber = Input.getPlayerNumber(device) or 0
  local platformUserNumber = Input.getPlatformUserNumber and Input.getPlatformUserNumber(device)
  return guid, productName, pidvid, playerNumber, platformUserNumber
end

-- locate all existing inputmap files for the specific device & vehicle
local function getInputmapPaths(devname, guid, productName, pidvid, vehicleName, suffix)
  local dirs = {}
  local recursion = 0
  if vehicleName then
    if suffix == 'inputmap.json' then
      table.insert(dirs, "vehicles/"..vehicleName)
    else
      table.insert(dirs, "vehicles/"..vehicleName.."/inputmaps")
      table.insert(dirs, "settings/inputmaps/"..vehicleName)
    end
  else
    table.insert(dirs, "settings/inputmaps")
    recursion = 0 -- used to be -1 during interaction refactor
  end
  local devicetype = string.split(devname, "%D+")[1] -- strip trailing number, if it exists (xinput0 -> xinput)
  if not devicetype then
    devicetype = devname or ""
  end
  local prefixes = { pidvid:lower() }
  if devicetype ~= "openxr" then
    table.insert(prefixes, devicetype:lower())
  end

  -- all prefixes are searched in a single tab-separated multimatch lookup per directory, then ordered by prefix priority
  local masks = {}
  for _,prefix in ipairs(prefixes) do
    table.insert(masks, prefix.."*."..suffix)
  end
  local mask = table.concat(masks, "\t")
  local singlePrefix = #prefixes == 1

  local result = {}
  for _,dir in ipairs(dirs) do
    local found = FS:findFiles(dir, mask, recursion, true, false)
    for _,prefix in ipairs(prefixes) do
      for _,path in ipairs(found) do
        if singlePrefix or string.startswith(string.lower(path:match("[^/]+$") or path), prefix) then
          if license.isAllowedInputmapPath(path) then
            table.insert(result, path)
          end
        end
      end
    end
  end
  return result
end

local function ListToSet(list)
  -- {'a', 'b', 'c'} ==> {a=true, b=true, c=true}
  local res = {}
  for _,e in ipairs(list) do
    res[e] = true
  end
  return res
end
local function updateDevicesList(oldDevices)
  -- refreshes the list of plugged input devices, notifying UI of new/removed devices
  local newDevicesList = Input.getRegisteredDevices()
  local newDevicesSet = ListToSet(newDevicesList)
  local newDevices = {}
  -- first check for new or modified devices (using devname as the id)
  for _,device in ipairs(newDevicesList) do
    local guid, productName, pidvid, playerNumber, platformUserNumber = getDeviceInfo(device)
    newDevices[device] = {guid, productName, pidvid, playerNumber, platformUserNumber}
    if oldDevices[device] == nil then
      -- a new devname was found: user just plugged it
      local isCommonDevice = device == 'mouse0' or device == 'keyboard0'

      if not isCommonDevice then
        log("I", "bindings", "Device connected: "..productName.." ("..device.."/0x"..pidvid..")")
        ui_toast(productName, _tr("ui.controls.device.connected"), "success")
      end
    else
      if oldDevices[device][3] ~= pidvid then
        -- the pidvid of a devname has changed! new drivers have been loaded by Windows, or user has replaced a device veeery quickly
        log("I", "bindings", "Device changed: "..productName.." ("..device.."/0x"..pidvid..")")
        ui_toast(productName, _tr("ui.controls.device.changed"), "info")
      end
    end
  end
  -- now check for removed devices
  for device,_ in pairs(oldDevices) do
    if newDevicesSet[device] == nil then
      -- local guid = oldDevices[device][1]
      local productName = oldDevices[device][2]
      local pidvid = oldDevices[device][3]
      log("I", "bindings", "Device unplugged: "..productName.." ("..device.."/0x"..pidvid..")")
      ui_toast(productName, _tr("ui.controls.device.unplugged"), "warning")
    end
  end
  return newDevices
end

-- set an active flag on the bindings depending on what actions are used in the jbeam file
local function markUnusedVehicleBindings(result, vehicleName, vehicleId)
  local vd = extensions.core_vehicle_manager.getVehicleData(vehicleId)
  -- now with the new inputmap.json file format: filter the bindings that are present...
  if not (vd and vd.vdata and vd.vdata.inputActions and vd.vdata.actionsEnabled) then return end

  local enabledActionsMap = {}
  for _, t in pairs(vd.vdata.actionsEnabled) do
    enabledActionsMap[t.name] = true
  end

  -- walk all keyboard/hardware bindings in reverse order
  for k = #result.bindings, 1, -1 do
    local b = result.bindings[k]
    b.unused = false -- reset everything by default
    if b.action then
      local actionClean = core_input_actions.uniqueNameToName(b.action, vehicleName)
      if not enabledActionsMap[actionClean] then
        b.unused = true
      end
      if vd.vdata.inputActions[actionClean] then
        vd.vdata.inputActions[actionClean].bound = true
      end
    end
  end

  --dump({"enabledActionsMap: ", enabledActionsMap})
end

-- read the default bindings, then custom diff bindings (if not "default"), join them, and return the resulting (full) list of bindings
local function getBindings(devname, guid, productName, pidvid, vehicleName, default)
  local curvePath = nil -- response curve correction file (lut/log/fcm/csv)
  local curveInverted = false
  if not default then
    -- hardcoded 'wheel' in file search, as some ffb steering wheels identify themselves as 'joystick', and users don't know what that implies
    curvePath = curvePath or getInputmapPaths("wheel", guid, productName, pidvid, vehicleName, "lut")[1]
    if curvePath then curveInverted = true end -- only for LUT files
    curvePath = curvePath or getInputmapPaths("wheel", guid, productName, pidvid, vehicleName, "log")[1]
    curvePath = curvePath or getInputmapPaths("wheel", guid, productName, pidvid, vehicleName, "fcm")[1]
    curvePath = curvePath or getInputmapPaths("wheel", guid, productName, pidvid, vehicleName, "csv")[1]
  end

  local devicetype = string.split(devname, "%D+")[1] -- strip trailing number, if it exists (xinput0 -> xinput)

  local diffPaths = {}
  if not default then diffPaths = getInputmapPaths(devicetype, guid, productName, pidvid, vehicleName, "diff") end
  local basePaths = getInputmapPaths(devicetype, guid, productName, pidvid, vehicleName, "json")
  arrayConcat(basePaths, getInputmapPaths(devicetype, guid, productName, pidvid, vehicleName, "inputmap.json"))

  local base = readBindingsFromDisk(basePaths, vehicleName, true)
  local diff = readBindingsFromDisk(diffPaths, vehicleName, false)

  local result = applyInputmapDiff(base, diff)
  if curvePath then result = applyResponseCurve(result, curvePath, curveInverted) end
  result.guid = guid
  result.vidpid = pidvid
  result.name = productName
  result.devicetype = devicetype

  return result
end

-- actions flagged "requiresActionEnabled" are only usable when the player's vehicle declares them in its "actionsEnabled" jbeam table
local function markGlobalVehicleBindings(bindings, vehicle)
  local activeActions = core_input_actions.getActiveActions()

  local enabledSet
  if vehicle then
    local vd = extensions.core_vehicle_manager.getVehicleData(vehicle:getID())
    if vd and vd.vdata and vd.vdata.actionsEnabled then
      enabledSet = {}
      for _, entry in pairs(vd.vdata.actionsEnabled) do
        if entry.name then enabledSet[entry.name] = true end
      end
    end
  end

  for _, b in ipairs(bindings) do
    local action = b.action and activeActions[b.action]
    if action and action.requiresActionEnabled and not (enabledSet and enabledSet[b.action]) then
      b.unused = true
    end
  end
end

local deviceBindingsCache = {}

local function getDeviceBindings(devname, info, vehicleName)
  local key = devname.."|"..tostring(info[1]).."|"..tostring(info[2]).."|"..tostring(info[3]).."|"..tostring(vehicleName)
  local cached = deviceBindingsCache[key]
  if not cached then
    cached = { bindings = getBindings(devname, info[1], info[2], info[3], vehicleName, false),
               defaultBindings = getBindings(devname, info[1], info[2], info[3], vehicleName, true) }
    deviceBindingsCache[key] = cached
  end

  return deepcopy(cached.bindings), deepcopy(cached.defaultBindings)
end

local function mergeBindingContents(contents, vehicleContents)
  -- fill/rewrite metadata (all except bindings themselves: guid, devtype...)
  for k,v in pairs(vehicleContents) do
    if k ~= "bindings" then contents[k] = v end
  end
  -- now append all new bindings
  for _,b in ipairs(vehicleContents.bindings) do
    table.insert(contents.bindings, deepcopy(b))
  end
end

local function getAllBindings(devices, assignedPlayers)
  local bindings = {}
  local defaultBindings = {}

  -- temp fix for having force feedback: wheel0 is before xinput0
  local sortedNodeKeys = tableKeys(devices)
  table.sort(sortedNodeKeys)

  for i, devname in ipairs(sortedNodeKeys) do
    local info = devices[devname] or {}
    local player = assignedPlayers[devname]

    -- normal bindings
    local contents, defaultContents = getDeviceBindings(devname, info)

    -- vehicle specific bindings
    local vehicle = getPlayerVehicle(player)
    if vehicle then
      local vehicleName = vehicle:getJBeamFilename()
      local vehicleContents, defaultVehicleContents = getDeviceBindings(devname, info, vehicleName)
      markUnusedVehicleBindings(vehicleContents, vehicleName, vehicle:getID())
      markUnusedVehicleBindings(defaultVehicleContents, vehicleName, vehicle:getID())
      mergeBindingContents(contents, vehicleContents)
      mergeBindingContents(defaultContents, defaultVehicleContents)
    end

    -- this is an unused feature for now
    --markGlobalVehicleBindings(contents.bindings, vehicle)

    for _,b in ipairs(contents.bindings) do b.player = player end
    for _,b in ipairs(defaultContents.bindings) do b.player = player end
    table.insert(bindings, {devname = devname, contents = contents})
    table.insert(defaultBindings, {devname = devname, contents = defaultContents})
  end

  return bindings, defaultBindings
end

local function getControlForAction(actionName)
  if not actionToControl then
    actionToControl = {}
    for _, device in ipairs(M.bindings) do
      for _, binding in ipairs(device.contents.bindings) do
        if not actionToControl[binding.action] then
          actionToControl[binding.action] = binding.control
        end
      end
    end
  end
  return actionToControl[actionName]
end

-- other actions bound to the same control as actionName, on the same device
local function getActionsSharingControls(actionName)
  local result = {}
  for _, device in ipairs(M.bindings) do
    local controls = {}
    for _, binding in ipairs(device.contents.bindings) do
      if binding.action == actionName and not binding.unused then controls[binding.control] = true end
    end
    if next(controls) then
      for _, binding in ipairs(device.contents.bindings) do
        if binding.action ~= actionName and not binding.unused and controls[binding.control] then
          result[binding.action] = true
        end
      end
    end
  end
  return tableKeysSorted(result)
end

local function notifyUI(reason)
  guihooks.triggerRawJS('ControllersChanged', Input.getControllersInfoJson())
  guihooks.trigger('AssignedPlayersChanged', M.assignedPlayers)

  -- strip actions from vehicles other than currently focused one (since those will show up with no bindings)
  local vehicle = getPlayerVehicle(0)
  local vehicleName = vehicle and vehicle:getJBeamFilename()
  local currentActions = {}
  for actionName,action in pairs(core_input_actions.getActiveActions()) do
    if action.vehicle == nil or action.vehicle == vehicleName then
      currentActions[actionName] = action
    end
  end

  local result = { actionCategories= core_input_categories,
               actions       = currentActions,
               bindingTemplate = fillNormalizeBindingDefaults({}),
               bindings      = M.bindings,             -- currently used bindings
               defaultBindings = M.defaultBindings,    -- original official bindings (if they existed). used as a starting point if user tries to re-add a deleted original binding
               reason = reason }
  guihooks.trigger('InputBindingsChanged', result)
end

local function notifyGE(reason)
  actionToControl = nil
  for i,s in pairs(ActionMap:getList())do
    for j,v in ipairs(s) do
      if v.name:endswith("ActionMap") then -- skip the editor (and similar) action maps
        scenetree[v.name]:clear()
      end
    end
  end

  -- ok, now look at all vehicles, which global actionmaps they use and update them
  local activeActions = core_input_actions.getActiveActions()
  for _,veh in ipairs(getAllVehicles()) do
    local vd = extensions.core_vehicle_manager.getVehicleData(veh:getId())
    for _, actionList in pairs(vd and vd.vdata and vd.vdata.triggerEventLinksDict or {}) do
      for _, linkList in pairs(actionList) do
        for _, lnk in pairs(linkList) do
          if lnk.namespace == 'common' then
            -- find the correction action
            lnk.inputAction = core_input_actions.upgradeAction(lnk.inputAction)
            local action = activeActions[lnk.inputAction]
            if action then
              action.namespace = 'common'
              vd.vdata.inputActions[lnk.inputAction] = action
              lnk.commonLua = true -- mark as being resolved within lua
            end
          end
        end
      end
    end
  end

  for _,data in pairs(M.bindings) do
    sendBindingsToGE(data.devname, data.contents.bindings, M.assignedPlayers[data.devname])
  end

  -- uncomment for creating a nice file to debug things
  --jsonWriteFile('current_bindings.json', M.bindings, true)
end
local function getFFBConfigForAction(veh, action)
  local driver = -1
  if gameplay_seatOccupants then
    driver = gameplay_seatOccupants.getDriverPlayer(veh:getId())
    if not driver then return nil end
  end
  local FFBID = veh:getFFBID(action, driver) -- will automatically return -1 if no player is seated there with an ffb input controller
  if FFBID < 0 then
    return nil
  end
  local ffbConfigString = be:getFFBConfig(FFBID)
  local state, ffbConfig = pcall(json.decode, ffbConfigString)
  if state == false then
    log('E', "", "Couldn't decode ffbconfig JSON: "..tostring(ffbConfig))
    return nil
  end
  if ffbConfig == nil then
    log("E", "", "Got a nil ffbConfig for vehicle with ID "..dumps(veh:getId())..", ffb action "..dumps(action).." and FFFBID "..dumps(FFBID))
    return nil
  end
  local state, ffbParams = pcall(json.decode, ffbConfig.ffbParamsJson)
  if state ~= true then
    log("E", "", "Couldn't parse FFB params: state:"..dumps(state).."\nffbParams: \n"..dumps(ffbParams).."\nffbParamsJson: "..dumps(ffbConfig.ffbParamsJson))
    return nil
  end
  ffbConfig.ffbParams = ffbParams
  return ffbConfig, FFBID
end

local function getFFBConfig(veh)
  local ffbConfig, FFBID
  local result = {}
  local action = "steering"

  ffbConfig, FFBID = getFFBConfigForAction(veh, action)
  if ffbConfig then
    result[action] = ffbConfig
    result[action]["FFBID"] = FFBID
  end
--trigger ffb start
  action = "accelerate"
  ffbConfig, FFBID = getFFBConfigForAction(veh, action)
  if ffbConfig then
    result[action] = ffbConfig
    result[action]["FFBID"] = FFBID
  end

  action = "brake"
  ffbConfig, FFBID = getFFBConfigForAction(veh, action)
  if ffbConfig then
    result[action] = ffbConfig
    result[action]["FFBID"] = FFBID
  end
--trigger ffb end
  return result
end

local function notifyFFB(reason)
  for _,veh in ipairs(getAllVehicles()) do
    veh:queueLuaCommand("hydros.onFFBConfigChanged("..serialize(getFFBConfig(veh))..")")
  end
  extensions.hook('onFFBConfigChanged')
end

local function onPlayerVehiclePresenceChanged(player)
  notifyFFB("player #"..player.." vehicle presence changed")
end

local function notifyExtensions(reason)
  extensions.hook('onInputBindingsChanged', M.assignedPlayers)
end

local function notifyAll(reason)
  notifyGE(reason)
  notifyFFB(reason) -- must happen after notifyGE
  notifyUI(reason) -- must happen after notifyFFB
  notifyExtensions(reason)
end

local function reloadBindings()
  table.clear(deviceBindingsCache)
  M.bindings, M.defaultBindings = getAllBindings(M.devices, M.assignedPlayers)
  notifyAll("some inputmap file changed")
end

local filechangeTimeout = nil -- seconds
-- filesystem notifications are unreliable on some platforms. since the input system relies on them in order to know when bindings have changed, this function allows to emulate a notification that we can trigger in certain cases where we know for sure (due to our own code) that a FS notification should be triggering
local function forceRefresh(seconds)
  filechangeTimeout = seconds
  if filechangeTimeout == nil then
    reloadBindings()
  end
end

-- remove custom user bindings of the desired device, reverting back to defaults
local function resetDeviceBindings(devname, guid, name, pidvid, vehicleName)
  for _,suffix in ipairs({"json", "diff"}) do
    for _,path in ipairs(getInputmapPaths(devname, guid, name, pidvid, vehicleName, suffix)) do
      FS:removeFile(path) -- will only be removed if stored in user folder (game install folder is read-only)
    end
  end
end

-- take a full set of customized bindings, compare them to the defaults (if they exist), and save the resulting diff on disk
local function saveBindingsFileToDisk(data, vehicleName)
  -- compute diff from default to desired data
  resetDeviceBindings(data.devicetype, data.guid, data.name, data.vidpid, vehicleName) -- revert to defaults (so we can read them and use as reference for diff)
  local defaultData = getBindings(data.devicetype, data.guid, data.name, data.vidpid, vehicleName, true)

  -- remove the "unused" flag from the bindings for comparing and writing to disk
  for k,v in pairs(defaultData.bindings) do v.unused = nil end
  for k,v in pairs(data.bindings) do v.unused = nil end

  local diffData = createBindingsDiff(defaultData, data)

  -- write the diff to disk
  if diffData == nil then return false end
  -- convert from vehicle__actionname to actionname. this name-mangling is needed to prevent collisions with other vehicles' action names
  for _,b in pairs(diffData.bindings or {}) do b.action = core_input_actions.uniqueNameToName(b.action, vehicleName) end
  for _,b in pairs(diffData.removed  or {}) do b.action = core_input_actions.uniqueNameToName(b.action, vehicleName) end

  local path = getWritingPath(vehicleName, data.devicetype, data.vidpid)
  if not jsonWriteFile(path, diffData, true) then -- some simple indentation
    log('E', 'bindings', "Couldn't write bindings file to: "..path)
    return false
  end
  log("D", "bindings", "Custom bindings for "..data.name.." ("..data.devicetype.."/"..data.vidpid..") at: "..path)
end

-- data bindings may have mixed vehicle/generic bindings. split them up and save in separate files when necessary
local function saveBindingsToDisk(data)
  local inputmapTemplate = deepcopy(data)
  inputmapTemplate.bindings = {}

  -- 'inputmaps' will hold the generic ("none") bindings as well as each vehicle's bindings

  -- first we initialize them as empty. this forces empty inputmaps to be saved too (instead of being ignored because UI didn't mention the vehicle in incoming data)
  local inputmaps = { none=deepcopy(inputmapTemplate) }
  local vehicle = getPlayerVehicle(0)
  if vehicle then
    inputmaps[vehicle:getJBeamFilename()] = deepcopy(inputmapTemplate)
  end

  -- then we add them with whatever 'data' came from the UI side
  for _,b in ipairs(data.bindings) do
    local vehicleName = core_input_actions.getActiveActions()[b.action].vehicle
    local vehicleNameStr = vehicleName or "none" -- temporarily rename to 'none' for during this function
    b.player = nil -- clear variable used to let UI know which player's binding this is
    table.insert(inputmaps[vehicleNameStr].bindings, b)
  end

  -- save each of the computed split inputmaps to a separate file
  for vehicleNameStr,v in sortedPairs(inputmaps) do
    local vehicleName = vehicleNameStr
    if vehicleName == "none" then vehicleName = nil end
    log("D", "bindings", "Saving "..tableSize(v.bindings).." bindings for vehicle: "..dumps(vehicleName))
    saveBindingsFileToDisk(v, vehicleName)
  end
  forceRefresh()
end

-- remove custom user bindings of currently plugged devices, reverting back to beamng-provided defaults
local function resetBindings(desiredDevName)
  log("I", "", "Resetting bindings for: "..dumps(desiredDevName))
  local resetAllDevices = desiredDevName == nil
  -- normal bindings
  for devname,info in pairs(M.devices) do
    if resetAllDevices or devname == desiredDevName then
      resetDeviceBindings(devname, info[1], info[2], info[3], nil)
    end
  end
  FS:removeFile(getWritingDir(nil))

  -- vehicle specific bindings
  for devname,info in pairs(M.devices) do
    if resetAllDevices or devname == desiredDevName then
      local vehicle = getPlayerVehicle(M.assignedPlayers[devname])
      if vehicle then
        local vehicleName = vehicle:getJBeamFilename()
        resetDeviceBindings(devname, info[1], info[2], info[3], vehicleName)
        FS:removeFile(getWritingDir(vehicleName))
      end
    end
  end

  forceRefresh()
end

local function setPlayerToDevice(devname, player)
  assignPlayerToDevice(devname, player)
  M.assignedPlayers[devname] = player
  M.bindings, M.defaultBindings = getAllBindings(M.devices, M.assignedPlayers)
  notifyAll("player #"..player.." assigned to device "..devname)
end

local function applyPlayerAssignments(assignments, reason)
  if type(assignments) ~= "table" then return false end
  local nextAssignments = {}
  for devname in pairs(M.devices) do
    local player = tonumber(assignments[devname]) or -1
    assignPlayerToDevice(devname, player)
    nextAssignments[devname] = player
  end
  M.assignedPlayers = nextAssignments
  M.bindings, M.defaultBindings = getAllBindings(M.devices, M.assignedPlayers)
  notifyAll(reason or "player assignments applied")
  return true
end

local function refreshAssignedPlayers(logEnabled, seatPlayers)
  local previousAssignments = M.assignedPlayers
  local nextAssignments = previousAssignments
  if M.autoAssignPlayersToDevices then
    nextAssignments = core_multiseat.getAssignedPlayers(M.devices, logEnabled == true, seatPlayers == true)
  end
  local changed = tableSize(previousAssignments) ~= tableSize(nextAssignments)
  if not changed then
    for devname, player in pairs(nextAssignments) do
      if previousAssignments[devname] ~= player then changed = true; break end
    end
  end
  if not changed then return M.assignedPlayers end

  M.assignedPlayers = nextAssignments
  M.bindings, M.defaultBindings = getAllBindings(M.devices, M.assignedPlayers)
  notifyAll("player assignments refreshed")
  return M.assignedPlayers
end

-- is called whenever player switches to a new vehicle, or to an existing vehicle, or exits a vehicle is not driving anymore
-- new vehicle may have been added to the level, or it may be replacing an existing vehicle (which gets removed)
-- that's why we simply re-read all vehicles' actions, instead of keeping track of which vehicle went away and which didn't
local function onVehicleSwitched(oldId, newId, player)
  -- always reload as with the new triggers, trucks can be vastly different depending on the configuration
  if M.autoAssignPlayersToDevices then
    M.assignedPlayers = core_multiseat.getAssignedPlayers(M.devices, true)
  end

  profilerPushEvent("inputBindings getAllBindings")
  M.bindings, M.defaultBindings = getAllBindings(M.devices, M.assignedPlayers)
  profilerPopEvent("inputBindings getAllBindings")

  local oldVehicle = getObjectByID(oldId)
  local newVehicle = getObjectByID(newId)
  local oldName = oldVehicle and oldVehicle:getJBeamFilename() or "<none>"
  local newName = newVehicle and newVehicle:getJBeamFilename() or "<none>"

  profilerPushEvent("inputBindings notifyAll")
  notifyAll("player #"..player.." switched from "..oldName.." to "..newName)
  profilerPopEvent("inputBindings notifyAll")
end

local function onVehicleSpawned(vehId, veh)
  if M.autoAssignPlayersToDevices then
    M.assignedPlayers = core_multiseat.getAssignedPlayers(M.devices, true)
  end
  M.bindings, M.defaultBindings = getAllBindings(M.devices, M.assignedPlayers)
end

-- Enable the commented out part below to get a imgui window of the live status of menu-related action maps. This is useful for debugging.
--[[
local trackedActionMaps = {
  MenuActionMap = true,
  MenuIndependent_cui_gameplay_interactActionMap = true,
  MenuIndependent_menu_item_upActionMap = true
}
local trackedActionMapRequestedState = {}

M.onUpdate = function()
  local im = ui_imgui
  if not im then return end
  local flags = im.WindowFlags_AlwaysAutoResize + im.WindowFlags_NoCollapse
  if im.Begin("Tracked ActionMaps##inputBindingsDebug", nil, flags) then
    local tableFlags = bit.bor(im.TableFlags_RowBg, im.TableFlags_Borders, im.TableFlags_SizingFixedFit)
    if im.BeginTable("TrackedActionMapsTable##inputBindingsDebug", 3, tableFlags) then
      im.TableSetupColumn("ActionMap", nil, 420)
      im.TableSetupColumn("Requested", nil, 80)
      im.TableSetupColumn("Live", nil, 80)
      im.TableNextColumn()
      im.Text("ActionMap")
      im.TableNextColumn()
      im.Text("Requested")
      im.TableNextColumn()
      im.Text("Live")
      im.TableNextColumn()

      for _, actionMapName in ipairs(tableKeysSorted(trackedActionMaps)) do
        local requestedState = trackedActionMapRequestedState[actionMapName]
        local actionMap = scenetree[actionMapName]
        local liveStateText = "missing"
        if actionMap then
          local ok, isEnabled = true, actionMap.enabled
          if ok then
            liveStateText = isEnabled and "enabled" or "disabled"
          else
            liveStateText = "unknown"
          end
        end

        local liveColor = im.ImVec4(1, 1, 0.35, 1)
        if liveStateText == "enabled" then
          liveColor = im.ImVec4(0.35, 1, 0.35, 1)
        elseif liveStateText == "disabled" then
          liveColor = im.ImVec4(1, 0.4, 0.4, 1)
        elseif liveStateText == "unknown" then
          liveColor = im.ImVec4(1, 0.7, 0.35, 1)
        end

        local requestedStateText = requestedState == nil and "n/a" or tostring(requestedState)
        im.Text(actionMapName)
        im.TableNextColumn()
        im.Text(requestedStateText)
        im.TableNextColumn()
        im.TextColored(liveColor, liveStateText)
        im.TableNextColumn()
      end
      im.EndTable()
    end
  end
  im.End()
end
--]]


local menuActionMapWatchEnabled = false

local function getActionNameFromMenuActionMap(actionMapName)
  local prefix = core_input_actions.menuIndependentPrefix
  if type(actionMapName) ~= "string" then return nil end
  if actionMapName == "MenuActionMap" then return nil end
  if not string.startswith(actionMapName, prefix) then return nil end
  local suffix = "ActionMap"
  if not string.endswith(actionMapName, suffix) then return nil end
  return actionMapName:sub(#prefix + 1, #actionMapName - #suffix)
end

local function notifyMenuActionMapStateChanged(actionName, enabled, actionMapName)
  if not menuActionMapWatchEnabled then return end
  actionName = actionName or getActionNameFromMenuActionMap(actionMapName)
  if not actionName then return end
  if core_input_actions.menuActionMapNames[(actionMapName or (core_input_actions.menuIndependentPrefix..actionName.."ActionMap"))] == nil then return end
  guihooks.trigger("MenuActionMapStateChanged", actionName, enabled == true)
end

local function getMenuActionStates()
  local result = {}
  for actionMapName,_ in pairs(core_input_actions.menuActionMapNames) do
    local actionName = getActionNameFromMenuActionMap(actionMapName)
    if actionName then
      local am = scenetree[actionMapName]
      result[actionName] = am and am.enabled == true
    end
  end
  return result
end

local function setMenuActionMapWatchEnabled(enabled)
  menuActionMapWatchEnabled = enabled == true
  return menuActionMapWatchEnabled
end

local function getMenuActionMapWatchEnabled()
  return menuActionMapWatchEnabled
end

local menuScrollActionMapActive = false

local function setMenuScrollActionMapEnabled(enabled)
  enabled = enabled == true
  if menuScrollActionMapActive == enabled then return menuScrollActionMapActive end
  local am = scenetree.findObject("MenuScrollActionMap")
  if not am then return false end
  if enabled then am:push() else am:pop() end
  menuScrollActionMapActive = enabled
  return menuScrollActionMapActive
end

local function getMenuScrollActionMapEnabled()
  return menuScrollActionMapActive
end

-- you can call either: setMenuActionEnabled(true, "menu_item_up")
-- or:                  setMenuActionEnabled(true, nil, "MenuIndependent_menu_item_upActionMap")
local function setMenuActionEnabled(enabled, actionName, actionMapName)
  local prefix = core_input_actions.menuIndependentPrefix
  actionMapName = actionMapName or prefix..actionName.."ActionMap"
  local isMenuIndependent = string.startswith(actionMapName, prefix)
  local isMenuActionMap = isMenuIndependent or (actionMapName == "MenuActionMap")
  if not isMenuActionMap then
    log("E", "", string.format("Failed to run setMenuActionEnabled(%q, %q, %q): the action map name '%q' isn't related to menus", enabled, actionName, actionMapName, actionMapName, prefix))
    return
  end
  local isMenuIndependentValid = not isMenuIndependent or (isMenuIndependent and (core_input_actions.menuActionMapNames[actionMapName] ~= nil))
  if not isMenuIndependentValid then
    log("E", "", string.format("Failed to run setMenuActionEnabled(%q, %q, %q): the %q action map name '%q' isn't recognized", enabled, actionName, actionMapName, prefix, actionMapName))
    return
  end
  local am = scenetree[actionMapName]
  if not am then
    log("E", "", string.format("Failed to run setMenuActionEnabled(%q, %q, %q): the action map '%q' does not exist", enabled, actionName, actionMapName, actionMapName))
    return
  end
  --[[
  if trackedActionMaps[actionMapName] then
    print(string.format("setMenuActionEnabled(%q, %q, %q)", enabled, actionName, actionMapName))
    trackedActionMapRequestedState[actionMapName] = enabled
    print(debug.tracesimple())
  end
  ]]
  local wasEnabled = am.enabled
  am:setEnabled(enabled)
  local nowEnabled = am.enabled
  if wasEnabled ~= nowEnabled or menuActionMapWatchEnabled then
    notifyMenuActionMapStateChanged(actionName, nowEnabled, actionMapName)
  end
  return nowEnabled
end

-- example: setMenuActionsEnabled({ menu_item_up = true, menu_item_down = false })
local function setMenuActionsEnabled(actionStates)
  if type(actionStates) ~= "table" then
    log("E", "", string.format("Failed to run setMenuActionsEnabled: expected table, got %q", type(actionStates)))
    return false
  end
  local result = {}
  for actionName, enabled in pairs(actionStates) do
    if type(enabled) == "boolean" then
      local nowEnabled = setMenuActionEnabled(enabled, actionName)
      if nowEnabled ~= nil then
        result[actionName] = nowEnabled == true
      end
    end
  end
  return result
end

local isPopupOpen = false
local modalPopupOpen = false
local currentRouteName = nil

local function setMenuActionMapEnabled(enabled)
  setMenuActionEnabled(enabled, nil, "MenuActionMap")
  if enabled then
    if M.isMenuActive ~= enabled then
      M.isMenuActive = enabled
      guihooks.trigger("MenuActionMapEnabled", enabled)
      extensions.hook("onMenuActionMapEnabled", enabled)
    end
    return
  end
  local wasMenuActive = M.isMenuActive
  local changed = false
  for actionMapName,_ in pairs(core_input_actions.menuActionMapNames) do
    local am = scenetree[actionMapName]
    local wasEnabled = am and am.enabled
    if wasEnabled ~= enabled then
      local nowEnabled = setMenuActionEnabled(enabled, nil, actionMapName)
      if wasEnabled ~= nowEnabled then changed = true end
    end
  end
  -- if changed then
    M.isMenuActive = enabled
    guihooks.trigger("MenuActionMapEnabled", enabled)
  -- end
  if wasMenuActive ~= enabled then extensions.hook("onMenuActionMapEnabled", enabled) end
end

local function getMenuActionMapEnabled()
  return M.isMenuActive
end

local function hasPopupInStateStack(stateStack)
  if type(stateStack) ~= "table" then return false end
  for _, stateName in ipairs(stateStack) do
    if type(stateName) == "string" and string.startswith(stateName, "/popup/") then
      return true
    end
  end
  return false
end

local function hasModalPopupInStateStack(stateStack)
  if type(stateStack) ~= "table" then return false end
  for _, stateName in ipairs(stateStack) do
    if type(stateName) == "string" and string.startswith(stateName, "/popup/") and not string.startswith(stateName, "/popup/activity/") then
      return true
    end
  end
  return false
end

local gameplayRouteNames = {play = true, multiseat = true, trackBuilder = true}

local function updateMenuActionMapState()
  local shouldEnable = isPopupOpen or (currentRouteName ~= nil and not gameplayRouteNames[currentRouteName])
  setMenuActionMapEnabled(shouldEnable)
end

local function onAfterRouteChange(context)
  local toRoute = context.toRoute
  currentRouteName = toRoute and toRoute.name or nil

  updateMenuActionMapState()
end

local function onUIStateTriggered(stateName, opened, stateStack)
  local wasPopupOpen = isPopupOpen
  modalPopupOpen = hasModalPopupInStateStack(stateStack)

  if hasPopupInStateStack(stateStack) then
    isPopupOpen = true
  elseif type(stateName) == "string" and string.startswith(stateName, "/popup/") then
    isPopupOpen = opened == true
  end

  if isPopupOpen ~= wasPopupOpen then
    updateMenuActionMapState()
  end
end

local function onUIInitialised()
  modalPopupOpen = false
end

local function isModalPopupOpen()
  return modalPopupOpen
end


local function getAssignedPlayers()
  return M.assignedPlayers
end

local wasVehicleSpecificBlocked
local function updateGFX(dtRaw)
  if filechangeTimeout then
    filechangeTimeout = filechangeTimeout - dtRaw
    if filechangeTimeout <= 0 then
      reloadBindings()
      filechangeTimeout = nil
    end
  end
  local isWalking = core_vehicle_manager and core_vehicle_manager.getPlayerVehicleData() and core_vehicle_manager.getPlayerVehicleData().mainPartName == "unicycle" and core_camera and core_camera.isWorldCamera()
  local splitScreenActive = render_splitScreen and render_splitScreen.getCurrentConfiguration() == true
  local blockVehicleSpecific = not splitScreenActive and isWalking == true
  if blockVehicleSpecific ~= wasVehicleSpecificBlocked then
    wasVehicleSpecificBlocked = blockVehicleSpecific
    local o = scenetree.findObject("VehicleSpecificActionMap")
    if o then o:setEnabled(not blockVehicleSpecific) end
  end
end

local function onFileChanged(filename, t)
  local actionsModified = string.startswith(filename, "/lua/ge/extensions/core/input/actions") and string.endswith(filename, "json")
  local bindingsModified = string.startswith(filename, "/settings/inputmaps/")
  -- vehicle specific inputmaps, see getInputmapPaths
  local vehicleBindingsModified = string.startswith(filename, "/vehicles/") and (string.find(filename, "/inputmaps/", 1, true) ~= nil or string.endswith(filename, ".inputmap.json"))
  if actionsModified or bindingsModified or vehicleBindingsModified then
    forceRefresh(0.1)
  end
end
local function onDeviceChanged()
  M.devices = updateDevicesList(M.devices)
  if M.autoAssignPlayersToDevices then
    M.assignedPlayers = core_multiseat.getAssignedPlayers(M.devices, true, true)
  end
  M.bindings, M.defaultBindings = getAllBindings(M.devices, M.assignedPlayers)
  notifyAll("a device changed")
end

local multiseatEnabled
local function onSettingsChanged()
  local newMultiseatEnabled = settings.getValue("multiseat")
  if newMultiseatEnabled == multiseatEnabled then return end
  multiseatEnabled = newMultiseatEnabled
  if core_multiseat.isApplyingConfiguration and core_multiseat.isApplyingConfiguration() then return end
  if M.autoAssignPlayersToDevices then
    M.assignedPlayers = core_multiseat.getAssignedPlayers(M.devices, true, true)
  end
  M.bindings, M.defaultBindings = getAllBindings(M.devices, M.assignedPlayers)
  notifyAll("multiseat changed")
end

local function deprecatedMenuActive(enabled)
  log("E", "", "bindings.menuActive has been deprecated in favour of the 'menuActionMapEnabled' boolean flag on javascript side (see main.js for examples). The default behaviour is probably working correctly already, in which case you can simply delete the call to menuActive. Stacktrace provided below so you can update the relevant code:")
  print(debug.tracesimple())
  M.setMenuActionMapEnabled(enabled)
end

local function onFirstUpdate()
  M.devices = updateDevicesList(M.devices)
  if M.autoAssignPlayersToDevices then
    M.assignedPlayers = core_multiseat.getAssignedPlayers(M.devices, true)
  end
  M.bindings, M.defaultBindings = getAllBindings(M.devices, M.assignedPlayers)
  notifyAll("input_bindings.lua init")
end

local function getUsedBindingsFiles()
  usedBindingFiles = {}
  reloadBindings()
  return usedBindingFiles
end

local function enableCustomModifier(player, enabled, modifier)
  ActionMap.enableCustomModifier(player, enabled, modifier)
end

local function stringToVersion(s)
  local a, b = s:match("^(%d+)%.(%d+)")
  return tonumber(a), tonumber(b)
end

local controlTranslations = {
  button6 = "rxaxis",
  button7 = "ryaxis",
}

-- migrate the old direct input sce_pad diff files to the new one
local function migrateScePadDiffFiles()
  local baseDir = getWritingDir(nil)
  -- get all subdirectories (recursive), plus the base directory itself
  local allEntries = FS:findFiles(baseDir, "*", -1, false, true) or {}
  table.insert(allEntries, 1, baseDir)
  for _, entry in ipairs(allEntries) do
    local stat = FS:stat(entry)
    if stat and stat.filetype == "dir" then
      local dir = entry
      local targetPath = dir.."/sce_pad_standard.diff"
      if not FS:fileExists(targetPath) then
        -- build candidate paths from settings/scePadGuids.json
        local sourcePath
        local candidatePaths = {}
        local settingsFile = "/settings/scePadGuids.json"
        local guids = jsonReadFile(settingsFile)
        for _, info in ipairs(guids) do
          if not info.skipMigration and type(info.id) == "string" then
            table.insert(candidatePaths, dir.."/"..string.lower(info.id)..".diff")
          end
        end
        for _, p in ipairs(candidatePaths) do
          if FS:fileExists(p) then
            sourcePath = p
            break
          end
        end
        if sourcePath then
          local data = jsonReadFile(sourcePath)
          if data then

            -- translate the two trigger buttons that we removed from the controller
            for _, binding in ipairs(data.bindings) do
              if controlTranslations[binding.control] then
                binding.control = controlTranslations[binding.control]
              end
            end
            -- overwrite only the requested identification fields
            data.devicetype = "gamepad"
            data.guid = "{0CE6054C-0000-0000-0000-504944564944}"
            data.imagePack = "ps5"
            data.vendorName = "Sony"
            data.version = 1
            data.vidpid = "sce_pad_standard"

            if jsonWriteFile(targetPath, data, true) then
              log('I', 'bindings', "Migrated Playstation inputmap: "..sourcePath.." -> "..targetPath)
            end
          end
        end
      end
    end
  end
end

local function migrationChecks()
  -- set the setting to show the input layout popup
  local updatedFromVersion = core_versionUpdate.updatedFromVersion()
  if not updatedFromVersion then return end
  local oldMajor, oldMinor = stringToVersion(updatedFromVersion)
  if settings.getValue('showedInputLayoutPopupV37') == nil then
    if oldMajor == 0 and oldMinor < 37 then
      settings.setValue('showedInputLayoutPopupV37', false)
    end
  end

  -- migrate sce_pad input map diffs to combined "sce_pad_standard.diff"
  if oldMajor == 0 and oldMinor < 38 then
    migrateScePadDiffFiles()
  end
end

local function onExtensionLoaded()
  migrationChecks()
end

local function getRecentDevices()
  recentDevices = recentDevices or getDevicesByRecentActivity()
  return recentDevices
end

local function onRecentDevicesChanged(_recentDevices)
  recentDevices = _recentDevices
  guihooks.trigger('RecentDevicesChanged', recentDevices)
end

M.onFirstUpdate = onFirstUpdate
M.resetBindings = resetBindings
M.saveBindingsToDisk = saveBindingsToDisk
M.notifyUI = notifyUI
M.menuActive = deprecatedMenuActive
M.setMenuActionMapEnabled = setMenuActionMapEnabled
M.getMenuActionMapEnabled = getMenuActionMapEnabled
M.setMenuActionEnabled = setMenuActionEnabled
M.setMenuActionsEnabled = setMenuActionsEnabled
M.setMenuActionMapWatchEnabled = setMenuActionMapWatchEnabled
M.getMenuActionMapWatchEnabled = getMenuActionMapWatchEnabled
M.getMenuActionStates = getMenuActionStates
M.setMenuScrollActionMapEnabled = setMenuScrollActionMapEnabled
M.getMenuScrollActionMapEnabled = getMenuScrollActionMapEnabled
M.getAssignedPlayers= getAssignedPlayers
M.setPlayerToDevice = setPlayerToDevice
M.applyPlayerAssignments = applyPlayerAssignments
M.refreshAssignedPlayers = refreshAssignedPlayers
M.onFileChanged = onFileChanged
M.onDeviceChanged = onDeviceChanged
M.onSettingsChanged = onSettingsChanged
M.onVehicleSwitched = onVehicleSwitched
M.onPlayerVehiclePresenceChanged = onPlayerVehiclePresenceChanged
M.onVehicleSpawned = onVehicleSpawned
M.updateGFX = updateGFX
M.getControlForAction = getControlForAction
M.getActionsSharingControls = getActionsSharingControls
M.getUsedBindingsFiles = getUsedBindingsFiles
M.enableCustomModifier = enableCustomModifier
M.getRecentDevices = getRecentDevices
M.getFFBConfigForAction = getFFBConfigForAction

M.onAfterRouteChange = onAfterRouteChange
M.onUIStateTriggered = onUIStateTriggered
M.onUIInitialised = onUIInitialised
M.isModalPopupOpen = isModalPopupOpen
M.onExtensionLoaded = onExtensionLoaded
M.onRecentDevicesChanged = onRecentDevicesChanged

return M
