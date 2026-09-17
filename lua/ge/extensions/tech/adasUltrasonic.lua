-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- External modules used.
local util = require('editor/tech/sensorConfiguration/utilities') -- A utility class for the sensor configuration editors.

local vid
local ultrasonics = {}
local last_readings = {}
local dtReading = 0
local parkAssist
local blindSpots
local visualised

local poiData
local initialized = false

local function runUpdate(type) -- 0 = blind spot only; 1 = full
  if not loaded then
    return
  end

  local readings = {}

  for i = (type == 0 and parkAssist) and 7 or 1, (type == 0 and not parkAssist) and 4 or 10 do
    local reading = extensions.tech_sensors.getUltrasonicReadings(ultrasonics[i])["distance"]
    table.insert(readings, reading)
  end

  if blindSpots then
    local i = (type == 0 and 1 or 7)
    if readings[i] < 2 or readings[i + 2] < 2 then
      ui_message("Blind spot left", 1, "Tech", "matterial_arrow_back")
    end
    if readings[i + 1] < 2 or readings[i + 3] < 2 then
      ui_message("Blind spot right", 1, "Tech", "material_arrow_forward")
    end
  end

  if type == 1 then
    local lowering_readings = {}

    for i = 1, 10 do
      local reading = extensions.tech_sensors.getUltrasonicReadings(ultrasonics[i])["distance"]
      if last_readings[i] < 9999 and reading < last_readings[i] then
        table.insert(lowering_readings, reading)
      end
      last_readings[i] = reading
    end

    if #lowering_readings > 0 then
      be:queueObjectLua(vid, string.format("extensions.tech_adasUltrasonic.applyBrakes(%f)", math.min(unpack(lowering_readings))))
    else
      be:queueObjectLua(vid, "extensions.tech_adasInput.apply(0, 'brake', 'safe')")
      be:queueObjectLua(vid, "extensions.tech_adasInput.apply(1, 'throttle', 'safe')")
    end
  end
end

local function setupSensors()
  -- Create ultrasonic setup
  local front = poiData.vehFront
  front = util.posVS2Coeffs(front, getObjectByID(vid))
  front = extensions.tech_pythonExport.coeffs2Python(front, getObjectByID(vid))
  local rear = poiData.vehRear
  rear = util.posVS2Coeffs(rear, getObjectByID(vid))
  rear = extensions.tech_pythonExport.coeffs2Python(rear, getObjectByID(vid))
  local positions = {vec3(front.x + 0.3, front.y - 0.2, front.z - 0.25), vec3(front.x - 0.3, front.y - 0.2, front.z - 0.25), -- fl_near, fr_near
                        vec3(front.x + 0.8, front.y - 0.1, front.z - 0.25), vec3(front.x - 0.8, front.y - 0.1, front.z - 0.25), -- fl_far, fr_far
                        vec3(rear.x + 0.3, rear.y + 0.2, rear.z - 0.25), vec3(rear.x - 0.3, rear.y + 0.2, rear.z - 0.25), -- rl_near, rr_near
                        vec3(rear.x + 0.8, rear.y + 0.1, rear.z - 0.25), vec3(rear.x - 0.8, rear.y + 0.1, rear.z - 0.25), -- rl_far, rr_far
                        vec3(1.05, -0.4, 0.95), vec3(-1.05, -0.4, 0.95) -- mirror_left, mirror_right
                      }

  local directions = {vec3(0.15, -0.85, 0), vec3(-0.15, -0.85, 0), -- fl_near, fr_near
                          vec3(0.5, -0.5, 0), vec3(-0.5, -0.5, 0), -- fl_far, fr_far
                          vec3(0.15, 0.85, 0), vec3(-0.15, 0.85, 0), -- rl_near, rr_near
                          vec3(0.5, 0.5, 0), vec3(-0.5, 0.5, 0), -- rl_far, rr_far
                          vec3(0.6, 0.4, 0), vec3(-0.6, 0.4, 0) -- mirror_left, mirror_right
                        }
  local args = {requestedUpdateTime = 0.1, fovY = 30.0, nearFarPlanes = {0.1, 3.0}, rangeRoundness = -2.35, rangeShape = 0.2, rangeFocus = 0.676, rangeDirectMaxCutoff = 3.0, sensitivity = 0.01, fixedWindowSize = 100, isVisualised = visualised, isStatic = false, isSnappingDesired = true, isForceInsideTriangle = true}

  if parkAssist or blindSpots then
    for i = (parkAssist and 1 or 7), 10 do
      args["pos"] = positions[i]
      args["dir"] = directions[i]
      table.insert(ultrasonics, extensions.tech_sensors.createUltrasonic(vid, args))
      table.insert(last_readings, 9999.9)
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not loaded then
    return
  elseif not initialized then
    if not poiData then
      return
    else
      setupSensors()
      initialized = true
    end
  end

  dtReading = dtReading + dtSim
  if dtReading > 0.1 then
    dtReading = 0
    be:queueObjectLua(vid, "extensions.tech_adasUltrasonic.initAdasUpdate()")
  end
end

local function receivePOI(data)
  poiData = lpack.decode(data)
end

local function load(vehid, args)
  if loaded then
    return
  end

  if not args then args = {} end

  parkAssist = args.parkAssist == nil and true or args.parkAssist
  blindSpots = args.blindSpots == nil and true or args.blindSpots
  visualised = args.isVisualised == nil and true or args.isVisualised

  -- Attempt to get the vehicle ID.
  vid = vehid
  if not vid or vid == -1 then
    return
  end

  assert(vid >= 0, "adasUltrasonic.lua - Failed to get a valid vehicle ID")

  be:queueObjectLua(vid, "extensions.tech_vehiclePOI.collectVehiclePOIData('tech_adasUltrasonic.receivePOI')")
  be:queueObjectLua(vid, string.format("extensions.tech_adasUltrasonic.setup(%s, %s, %s)", tostring(parkAssist), tostring(blindSpots), tostring(args.hasCrawl == nil and true or args.hasCrawl)))

  be:queueObjectLua(vid, "input.event('brake', 0)")
  be:queueObjectLua(vid, "input.event('throttle', 0)")

  loaded = true

  ui_message("Ultrasonic ADAS extension loaded", 5, "Tech", "forward")
end

local function unload()
  loaded = false
  initialized = false
  for _, ultrasonic in ipairs(ultrasonics) do
    extensions.tech_sensors.removeSensor(ultrasonic)
  end

  be:queueObjectLua(vid, "extensions.tech_adasInput.apply(0, 'brake', 'safe')")
  be:queueObjectLua(vid, "extensions.tech_adasInput.apply(1, 'throttle', 'safe')")

  ultrasonics = {}
  last_readings = {}
  poiData = nil
  log('I', 'ADAS', 'ultrasonic ADAS extension unloaded')
  ui_message("Ultrasonic ADAS extension unloaded", 5, "Tech", "forward")
end

-- Public interface
M.onUpdate            = onUpdate
M.onExtensionLoaded   = function() log('I', 'ADAS', 'ultrasonic ADAS extension loaded') end
M.onExtensionUnloaded = unload
M.load                = load
M.unload              = unload
M.runUpdate           = runUpdate
M.receivePOI          = receivePOI

return M