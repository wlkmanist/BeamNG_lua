--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
This module contains a set of functions which manipulate behaviours of vehicles.
]]

local M = {}

local jbeamUtils = require("jbeam/utils")


local function _cleanupRows(row)
  -- clean some commonly leaking things ...
  row.nodeOffset = nil
  row.skinName = nil
end

local function processEvents(objID, vehicleObj, vehicle)
  profilerPushEvent('processEvents')
  if vehicle.events ~= nil then
    for _, ab in pairs(vehicle.events) do
      _cleanupRows(ab)
    end
    --extensions.core_input_actions.updateVehiclesActions()
    --log('D', "jbeam.events","- found ".. #vehicle.events .." Events")
  end
  profilerPopEvent('processEvents')
end

local function processTriggers(objID, vehicleObj, vehicle)
  profilerPushEvent('processTriggers')

  if vehicle.triggers ~= nil and vehicleObj then
    local trigger_count = 0

    for _, ab in pairs(vehicle.triggers) do
      _cleanupRows(ab)
      local abid = vehicleObj:addTrigger()
      if abid < 0 then
        log('E', 'jbeam.events', 'unable to create Trigger')
        goto continue
      end
      if abid ~= ab.cid then
        log('E', 'jbeam.events', 'Trigger cId desync: ' .. dumps(ab) .. ' / ' .. tostring(abid) ..  ' != ' .. tostring(ab.cid))
        goto continue
      end

      ab.abid = abid
      local abo = vehicleObj:getTrigger(abid)
      if abo ~= nil then
        trigger_count = trigger_count + 1
        -- now clean up the input data
        local rotDeg = vec3(ab.rotation)
        ab.rotation        = vec3(math.rad(rotDeg.x), math.rad(rotDeg.y), math.rad(rotDeg.z))
        ab.translation     = vec3(ab.translation)

        abo:set(tonumber(ab.idRef), tonumber(ab.idX), tonumber(ab.idY))

        if ab.baseTranslation ~= nil then
          ab.baseTranslation = vec3(ab.baseTranslation)
          abo.baseTranslation = ab.baseTranslation
        end
        if ab.translationOffset ~= nil then
          ab.translationOffset = vec3(ab.translationOffset)
          abo.translationOffset = ab.translationOffset
        end
        if ab.baseRotation ~= nil then
          local rot = vec3(ab.baseRotation)
          ab.baseRotation = vec3(math.rad(rot.x), math.rad(rot.y), math.rad(rot.z))
          abo.baseRotation = ab.baseRotation
        end
        if ab.color then
          abo.color = ColorF(ab.color[1], ab.color[2], ab.color[3], ab.color[4])
        end
        if type(ab.label) == 'string' then
          abo.label = ab.label
        end
        if ab.type == 'box' then
          abo.typeId = 0
        elseif ab.type == 'sphere' then
          abo.typeId = 1
        end

        local typeStr = ab.type or 'box'
        if typeStr == 'box' and type(ab.size) == 'table' then
          ab.size = vec3(ab.size)
          abo:setBoxSize(ab.size)
        elseif typeStr == 'sphere' and type(ab.size) == 'number' then
            abo:setSphereSize(ab.size)
        end

        abo.visibleDistance = 0.15

        abo:update(ab.translation, ab.rotation, true, 0)

        if ab.alphaOnUsed then
          abo:setAlphaOnUsed(ab.alphaOnUsed)
        end
      else
        log('E', 'trigger', "Trigger not found: " .. dumps(ab))
      end
      ::continue::
    end

    --log('D', "jbeam.events","- added ".. trigger_count .." triggers")

    -- enable debug drawing for the triggers
    --VehicleTrigger.debug = true

    if trigger_count > 0 then
      extensions.load('core_vehicleTriggers')
    end
  end

  profilerPopEvent('processTriggers')
end

-- Legacy triggerEventLinks (v1) point at vehicle.events; triggerEventLinks2 uses inputActions + link metadata.
-- Normalize v1 links at load time so execute/hover/debug paths match v2. Existing entries from *.interaction.json win.
local function findTriggerRow(vehicle, triggerId)
  if triggerId == nil or vehicle.triggers == nil then return nil end
  local row = vehicle.triggers[triggerId]
  if row == nil then
    for _, ab in pairs(vehicle.triggers) do
      if ab.id == triggerId or ab.name == triggerId or tostring(ab.cid) == tostring(triggerId) then
        row = ab
        break
      end
    end
  end
  return row
end

local function getNonEmptyTriggerLabel(vehicle, triggerId)
  local row = findTriggerRow(vehicle, triggerId)
  if not row or type(row.label) ~= 'string' then return nil end
  local s = row.label:match('^%s*(.-)%s*$')
  if s == nil or s == '' then return nil end
  return s
end

local function ensureVehicleInputActionFromV1TargetEvent(vehicle, eventId, evt, triggerLabel, triggerId)
  if eventId == nil or evt == nil then return end
  vehicle.inputActions = vehicle.inputActions or {}
  if vehicle.inputActions[eventId] ~= nil then return end
  local title = evt.title or evt.name
  local tl = triggerLabel and triggerLabel:match('^%s*(.-)%s*$')
  local usedTriggerLabel = tl ~= nil and tl ~= ''
  if usedTriggerLabel then
    title = tl
  end
  vehicle.inputActions[eventId] = {
    title = title,
    desc = evt.desc,
    onDown = evt.onDown,
    onUp = evt.onUp,
    onChange = evt.onChange,
    ctx = evt.ctx or 'vlua',
    cat = evt.cat or 'vehicle_specific',
    order = evt.order,
    icon = evt.icon,
  }
  if usedTriggerLabel and triggerId ~= nil then
    local row = findTriggerRow(vehicle, triggerId)
    if row then
      row.label = ''
    end
  end
end

local function upgradeLegacyTriggerEventLinksToV2(vehicle)
  local dict = vehicle.triggerEventLinksDict
  if type(dict) ~= 'table' then return end

  for _, actionMap in pairs(dict) do
    if type(actionMap) == 'table' then
      for _, linkList in pairs(actionMap) do
        if type(linkList) == 'table' then
          for _, lnk in ipairs(linkList) do
            if type(lnk) == 'table' and lnk.targetEvent and lnk.version ~= 2 then
              local eventId = lnk.targetEventId
              local evt = lnk.targetEvent
              if eventId and evt then
                ensureVehicleInputActionFromV1TargetEvent(vehicle, eventId, evt, getNonEmptyTriggerLabel(vehicle, lnk.triggerId), lnk.triggerId)
                lnk.version = 2
                lnk.triggerInput = lnk.triggerInput or lnk.action
                lnk.inputAction = eventId
                lnk.namespace = 'vehicle'
              end
            end
          end
        end
      end
    end
  end
end

local function processTriggerEventLinks(objID, vehicleObj, vehicle)
  profilerPushEvent('processTriggerEventLinks')

  -- support for old triggerEventLinks sections
  if vehicle.triggerEventLinks ~= nil then
    log(
      'W',
      'jbeam.events',
      string.format(
        'Legacy vehicle triggerEventLinks (v1) present; prefer triggerEventLinks2 with *.interaction.json inputActions. model=%s dir=%s',
        tostring(vehicle.model),
        tostring(vehicle.vehicleDirectory)
      )
    )
    vehicle.triggerEventLinksDict = {}

    for _, lnk in pairs(vehicle.triggerEventLinks) do
      if not lnk.targetEventId then
        print("targetEventId is missing: " .. dumps(lnk))
        goto continue2
      end
      if not lnk.triggerId then
        print("triggerId is missing or wrong: " .. dumps(lnk))
        goto continue2
      end
      if not lnk.action then
        print("action is missing: " .. dumps(lnk))
        goto continue2
      end
      -- now link the event
      if not vehicle.events[lnk.targetEventId] then
        print("targetEvent is missing / wrong: " .. dumps(lnk))
        goto continue2
      end

      local newTriggerId = lnk.triggerId

      lnk.targetEvent = vehicle.events[lnk.targetEventId]

      if not vehicle.triggerEventLinksDict[newTriggerId] then vehicle.triggerEventLinksDict[newTriggerId] = {} end
      if not vehicle.triggerEventLinksDict[newTriggerId][lnk.action] then vehicle.triggerEventLinksDict[newTriggerId][lnk.action] = {} end
      table.insert(vehicle.triggerEventLinksDict[newTriggerId][lnk.action], lnk)

      ::continue2::
    end
  end

  -- support for latest triggerEventLinks2 section
  if vehicle.triggerEventLinks2 ~= nil then
    vehicle.triggerEventLinksDict = vehicle.triggerEventLinksDict or {}
    vehicle.actionsEnabled = vehicle.actionsEnabled or {}

    for _, lnk in pairs(vehicle.triggerEventLinks2) do
      if not lnk.triggerId then
        print("triggerId is missing or wrong: " .. dumps(lnk))
        goto continue3
      end
      if not lnk.triggerInput then
        print("triggerInput is missing: " .. dumps(lnk))
        goto continue3
      end
      if not lnk.inputAction then
        print("inputAction is missing: " .. dumps(lnk))
        goto continue3
      end
      lnk.version = 2
      -- support common and per-vehicle bindings
      local namespace, inputActionName = string.match(lnk.inputAction, "^(%a+):(.*)")
      if namespace == nil then
        inputActionName = lnk.inputAction
        namespace = 'vehicle'
      end
      lnk.inputAction = inputActionName
      lnk.namespace = namespace

      local newTriggerId = lnk.triggerId

      if not vehicle.triggerEventLinksDict[newTriggerId] then vehicle.triggerEventLinksDict[newTriggerId] = {} end
      if not vehicle.triggerEventLinksDict[newTriggerId][lnk.triggerInput] then vehicle.triggerEventLinksDict[newTriggerId][lnk.triggerInput] = {} end
      table.insert(vehicle.triggerEventLinksDict[newTriggerId][lnk.triggerInput], lnk)

      ::continue3::
    end
  end
  upgradeLegacyTriggerEventLinksToV2(vehicle)

  profilerPopEvent('processTriggerEventLinks')
end


local function process(objID, vehicleObj, vehicle)
  profilerPushEvent('jbeam/events.process')

  processEvents(objID, vehicleObj, vehicle)
  processTriggers(objID, vehicleObj, vehicle)
  processTriggerEventLinks(objID, vehicleObj, vehicle)

  profilerPopEvent('jbeam/events.process')
end

M.process = process

return M
