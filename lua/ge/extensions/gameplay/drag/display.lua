-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = ""

local rand

local startTree = false
local treeTimer = 0
local treeFinished = false
local dragData

--TODO: if there is a prefab in the scene, just look at it and use its lights and display.
local function initTree()
  local treeLights = {
    {
      stageLights = {
        prestageLight  = {obj = scenetree.findObject("Prestagelight_r"), anim = "prestage"},
        stageLight     = {obj = scenetree.findObject("Stagelight_r"),    anim = "prestage"}
      },
      countDownLights = {
        amberLight1    = {obj = scenetree.findObject("Amberlight1_R"), anim = "tree"},
        amberLight2    = {obj = scenetree.findObject("Amberlight2_R"), anim = "tree"},
        amberLight3    = {obj = scenetree.findObject("Amberlight3_R"), anim = "tree"},
        greenLight     = {obj = scenetree.findObject("Greenlight_R"),  anim = "tree"},
        redLight       = {obj = scenetree.findObject("Redlight_R"),  anim = "tree"},
      }
    },
    {
      stageLights = {
        prestageLight  = {obj = scenetree.findObject("Prestagelight_l"), anim = "prestage"},
        stageLight     = {obj = scenetree.findObject("Stagelight_l"),    anim = "prestage"}
      },
      countDownLights = {
        amberLight1    = {obj = scenetree.findObject("Amberlight1_L"), anim = "tree"},
        amberLight2    = {obj = scenetree.findObject("Amberlight2_L"), anim = "tree"},
        amberLight3    = {obj = scenetree.findObject("Amberlight3_L"), anim = "tree"},
        greenLight     = {obj = scenetree.findObject("Greenlight_L"),  anim = "tree"},
        redLight       = {obj = scenetree.findObject("Redlight_L"),  anim = "tree"}
      }
    }
  }
  if not treeLights then
    log("E", logTag, "Tried to get the christmasTree but there is none in the scene")
    return
  end
  return treeLights
end

local function initDisplay()
  local displayDigits = {
    timeDigits = {},
    speedDigits = {}
  }
  local time = {}
  local speed = {}
  for i=1, 5 do
    local timeDigit = scenetree.findObject("display_time_" .. i .. "_r")
    table.insert(time, timeDigit)

    local speedDigit = scenetree.findObject("display_speed_" .. i .. "_r")
    table.insert(speed, speedDigit)
  end
  table.insert(displayDigits.timeDigits, time)
  table.insert(displayDigits.speedDigits, speed)

  time = {}
  speed = {}

  for i=1, 5 do
    local timeDigit = scenetree.findObject("display_time_" .. i .. "_l")
    table.insert(time, timeDigit)

    local speedDigit = scenetree.findObject("display_speed_" .. i .. "_l")
    table.insert(speed, speedDigit)
  end
  table.insert(displayDigits.timeDigits, time)
  table.insert(displayDigits.speedDigits, speed)

  if not displayDigits then
    log("E", logTag, "Tried to get the display digits but there is none in the scene")
    return
  end
  return displayDigits
end

local function init()
  dragData.strip.treeLights = initTree()
  dragData.strip.displayDigits = initDisplay()
end

local function clearLights()
  log("I", logTag, "Clear all the lights")
  rand = math.random() + 2

  if not dragData then return end
  for _, laneTree in ipairs(dragData.strip.treeLights) do
    for _,group in pairs(laneTree) do
      for _,light in pairs(group) do
        if light.obj then
          light.obj:setHidden(true)
        end
      end
    end
  end
end

local function clearDisplay()
  log("I", logTag, "Clear all the displays")
  if not dragData then return end
  for _, digitTypeData in pairs(dragData.strip.displayDigits) do
    for _,laneTypeData in ipairs(digitTypeData) do
      for _,digit in ipairs(laneTypeData) do
        digit:setHidden(true)
      end
    end
  end
end

local function clearAll()
  clearLights()
  clearDisplay()
  math.randomseed(os.time())
  treeTimer = 0
  treeFinished = false
  startTree = false
end

local function onExtensionLoaded()
  if gameplay_drag_general then
    dragData = gameplay_drag_general.getData()
  end
  init()
  clearAll()
end

local function updateDisplay(vehId)
  local timeDisplayValue = {}
  local speedDisplayValue = {}
  local timeDigits = {}
  local speedDigits = {}

  local lane = dragData.racers[vehId].lane

  local timeVal =  dragData.racers[vehId].timers.time_1_4.value
  local velVal = dragData.racers[vehId].timers.velAt_1_4.value * 2.237 -- convert from m/s to mph

  timeDigits = dragData.strip.displayDigits.timeDigits[lane]
  speedDigits = dragData.strip.displayDigits.speedDigits[lane]

  if timeVal < 10 then
    table.insert(timeDisplayValue, "empty")
  end

  if velVal < 100 then
    table.insert(speedDisplayValue, "empty")
  end

  -- Three decimal points for time
  for num in string.gmatch(string.format("%.3f", timeVal), "%d") do
    table.insert(timeDisplayValue, num)
  end

  -- Two decimal points for speed
  for num in string.gmatch(string.format("%.2f", velVal), "%d") do
    table.insert(speedDisplayValue, num)
  end

  if #timeDisplayValue > 0 and #timeDisplayValue < 6 then
    for i,v in ipairs(timeDisplayValue) do
      timeDigits[i]:preApply()
      timeDigits[i]:setField('shapeName', 0, "art/shapes/quarter_mile_display/display_".. v ..".dae")
      timeDigits[i]:setHidden(false)
      timeDigits[i]:postApply()
    end
  end

  for i,v in ipairs(speedDisplayValue) do
    speedDigits[i]:preApply()
    speedDigits[i]:setField('shapeName', 0, "art/shapes/quarter_mile_display/display_".. v ..".dae")
    speedDigits[i]:setHidden(false)
    speedDigits[i]:postApply()
  end
end

local timerFlag = false
local function onUpdate(dtReal, dtSim, dtRaw)
  if startTree then
    treeTimer = treeTimer + dtSim
    if dragData.prefabs.christmasTree.treeType == ".400" then
      if treeTimer > rand and not timerFlag then
        treeTimer = 0
        timerFlag = true
        for vehId, racer in pairs(dragData.racers) do
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight1.obj:setHidden(false)
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight2.obj:setHidden(false)
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight3.obj:setHidden(false)
        end
      end
      if timerFlag and treeTimer >= 0.4 then
        for vehId, racer in pairs(dragData.racers) do
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight1.obj:setHidden(true)
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight2.obj:setHidden(true)
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight3.obj:setHidden(true)
          dragData.strip.treeLights[racer.lane].countDownLights.greenLight.obj:setHidden(racer.isDesqualified)
          extensions.hook("startRaceFromTree", vehId)
        end
        treeFinished = true
        startTree = false
        timerFlag = false
        return
      end
    else
      for vehId, racer in pairs(dragData.racers) do
        if treeTimer > 1.0 and treeTimer < 1.5 then
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight1.obj:setHidden(false)
        elseif treeTimer > 1.5 and treeTimer < 2.0 then
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight1.obj:setHidden(true)
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight2.obj:setHidden(false)
        end
        if treeTimer > 2.0 and treeTimer < 2.5 then
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight2.obj:setHidden(true)
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight3.obj:setHidden(false)
        end
        if treeTimer > 2.5 then
          dragData.strip.treeLights[racer.lane].countDownLights.amberLight3.obj:setHidden(true)
          dragData.strip.treeLights[racer.lane].countDownLights.greenLight.obj:setHidden(racer.isDesqualified)
          --Race Start
          extensions.hook("startRaceFromTree", vehId)
          treeFinished = true
        end
      end
      if treeFinished then
        startTree = false
        return
      end
    end
  end
end

local function preStageEnded(vehId)
  if not vehId or not dragData then return end
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.prestageLight.obj:setHidden(false)
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj:setHidden(true)
end

local function preStageStarted(vehId)
  if not vehId or not dragData then return end
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.prestageLight.obj:setHidden(true)
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj:setHidden(true)
end

local function stageStarted(vehId)
  -- if not vehId or not dragData then return end
  -- if dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.prestageLight.obj:isHidden() then
  --   dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.prestageLight.obj:setHidden(false)
  -- end
end

local function stageEnded(vehId)
  if not vehId or not dragData then return end
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.prestageLight.obj:setHidden(false)
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj:setHidden(false)
end

local function dragRaceStageEndedDeep(vehId)
  if not vehId or not dragData then return end
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.prestageLight.obj:setHidden(true)
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj:setHidden(false)
end

local function dragRaceOutForward(vehId)
  if not vehId or not dragData then return end
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.prestageLight.obj:setHidden(true)
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj:setHidden(true)
end
local function dragRaceOutParallel(vehId)
  if not vehId or not dragData then return end
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj:setHidden(true)
end

local function startDragCountdown()
  if not dragData then return end
  startTree = true
end

local function jumpDescualifiedDrag(vehId)
  if not vehId or not dragData then return end
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.prestageLight.obj:setHidden(true)
  dragData.strip.treeLights[dragData.racers[vehId].lane].stageLights.stageLight.obj:setHidden(true)
  dragData.strip.treeLights[dragData.racers[vehId].lane].countDownLights.amberLight1.obj:setHidden(true)
  dragData.strip.treeLights[dragData.racers[vehId].lane].countDownLights.amberLight2.obj:setHidden(true)
  dragData.strip.treeLights[dragData.racers[vehId].lane].countDownLights.amberLight3.obj:setHidden(true)
  dragData.strip.treeLights[dragData.racers[vehId].lane].countDownLights.greenLight.obj:setHidden(true)
  dragData.strip.treeLights[dragData.racers[vehId].lane].countDownLights.redLight.obj:setHidden(false)
end

local function dragRaceStarted()
  startTree = false
  treeFinished = false
end

local function dragRaceEndLineReached(vehId)
  updateDisplay(vehId)
end

local function dragRaceVehicleStopped()
  clearAll()
end

local function resetDragRaceValues()
  clearAll()
end

M.clearAll = clearAll
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded

--HOOKS
M.preStageEnded = preStageEnded
M.preStageStarted = preStageStarted

M.stageStarted = stageStarted
M.stageEnded = stageEnded
M.dragRaceOutForward = dragRaceOutForward
M.dragRaceOutParallel = dragRaceOutParallel
M.dragRaceStageEndedDeep = dragRaceStageEndedDeep

M.startDragCountdown = startDragCountdown
M.jumpDescualifiedDrag = jumpDescualifiedDrag

M.dragRaceStarted = dragRaceStarted
M.dragRaceEndLineReached = dragRaceEndLineReached

M.dragRaceVehicleStopped = dragRaceVehicleStopped
M.resetDragRaceValues = resetDragRaceValues

return M